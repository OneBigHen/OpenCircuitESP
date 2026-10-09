import importlib.util,json,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("ringcollector",ROOT/"collector"/"app.py")
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
DEVICE="F8:79:99:F7:03:AD"

def checksum(body):return bytes(body)+bytes([m.checksum(body)])
def sample():
    seen=int(time.time())
    rec=bytearray(23)
    rec[0]=0x0c;rec[1:4]=((seen-m.EPOCH-150)&0xffffff).to_bytes(3,"big")
    rec[4]=65;rec[5]=55;rec[7]=120;rec[8]=97
    return checksum(b"\x4c\x00\x00"+rec),seen
def descriptor():
    b=bytearray(19)
    b[0]=0x87;b[1]=84;b[2]=2
    b[4:6]=(12).to_bytes(2,"big")
    b[6:8]=(331).to_bytes(2,"big");b[8:10]=(329).to_bytes(2,"big")
    b[14:16]=(4050).to_bytes(2,"big");b[17]=255
    b[-1]=m.checksum(b[:-1]);return bytes(b)

class TestCollector(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.db=m.connect(Path(self.temp.name)/"test.db")
    def tearDown(self):self.db.close();self.temp.cleanup()
    def row(self,b,seen,device=DEVICE):
        return json.dumps({"device":device,"channel":0,"seen":seen,"raw":b.hex()}).encode()
    def test_history_status_and_retry_dedup(self):
        frame,now=sample();s=descriptor()
        body=self.row(frame,now)+b"\n"+self.row(s,now)+b"\n"
        self.db.execute("BEGIN IMMEDIATE")
        self.assertEqual(m.ingest(self.db,body),2);self.db.commit()
        x=m.status(self.db)["devices"][DEVICE]
        self.assertEqual(x["hr_bpm"],65)
        self.assertEqual(x["hrv_rmssd_ms"],55)
        self.assertEqual(x["spo2_pct"],97)
        self.assertEqual(x["respiratory_rate"],15)
        self.assertEqual(x["battery_pct"],84)
        self.assertEqual(x["frame_count"],2)
        m.ingest(self.db,body)
        self.assertEqual(m.status(self.db)["devices"][DEVICE]["frame_count"],2)
    def test_corruption_rejected(self):
        frame,now=sample();bad=bytearray(frame);bad[-1]^=1
        with self.assertRaisesRegex(ValueError,"checksum"):
            m.ingest(self.db,self.row(bad,now))
    def test_unrecognized_device_rejected(self):
        frame,now=sample()
        with self.assertRaisesRegex(ValueError,"device"):
            m.ingest(self.db,self.row(frame,now,device="other"))
    def test_no_fabricated_daily_steps(self):
        frame,now=sample();m.ingest(self.db,self.row(frame,now))
        self.assertNotIn("daily_steps",m.status(self.db)["devices"][DEVICE])
    def test_time_wrap(self):
        seen=m.EPOCH+0x01200010
        self.assertEqual(m.timestamp_from_counter(0xfffff0,seen),m.EPOCH+0x00fffff0)
if __name__=="__main__":unittest.main()
