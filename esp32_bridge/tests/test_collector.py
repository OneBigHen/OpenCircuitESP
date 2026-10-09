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

    def test_same_status_frame_at_different_times_is_preserved(self):
        s=descriptor();now=int(time.time())
        m.ingest(self.db,self.row(s,now))
        m.ingest(self.db,self.row(s,now+1))
        self.assertEqual(m.status(self.db)["devices"][DEVICE]["frame_count"],2)
        self.assertEqual(m.status(self.db)["devices"][DEVICE]["last_frame"],now+1)
    def test_cannot_claim_sync_without_both_end_markers(self):
        frame,now=sample();m.ingest(self.db,self.row(frame,now))
        with self.assertRaisesRegex(ValueError,"missing recent"):
            m.mark_complete(self.db,json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600}))
        self.assertIsNone(m.status(self.db)["devices"][DEVICE]["last_complete_sync"])
    def test_can_mark_sync_after_both_end_markers(self):
        now=int(time.time())
        for ch in (0,3):
            self.db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",
                            (DEVICE,ch,now,80,b"\x50\x00\x00\x15\x12\x00\x00\x00\x01","marker-"+str(ch)))
        stamp=m.mark_complete(self.db,json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600}))
        self.assertIsInstance(stamp,int)
        self.assertEqual(m.status(self.db)["devices"][DEVICE]["sync_state"],"healthy")
    def test_migrates_existing_frame_unique_key(self):
        self.db.close()
        path=Path(self.temp.name)/"old.db"
        import sqlite3
        db=sqlite3.connect(path)
        db.execute("""CREATE TABLE frames(device TEXT,channel INTEGER,seen INTEGER,
                   opcode INTEGER,raw BLOB,digest TEXT,UNIQUE(device,channel,digest))""")
        db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",(DEVICE,0,123,135,b"abc","hash"))
        db.commit();db.close()
        migrated=m.connect(path)
        migrated.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",(DEVICE,0,124,135,b"abc","hash"))
        self.assertEqual(migrated.execute("SELECT COUNT(*) FROM frames").fetchone()[0],2)
        migrated.close()

    def test_empty_channel_ack_counts_as_end_evidence(self):
        now=int(time.time())
        for ch in (0,3):
            payload=b"\x82\xff\x00\x7d"
            self.db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",
                            (DEVICE,ch,now,130,payload,"empty-"+str(ch)))
        self.assertIsInstance(m.mark_complete(self.db,json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600})),int)
    def test_rejects_mismatched_marker_times(self):
        now=int(time.time())
        for ch,offset in ((0,0),(3,4000)):
            self.db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",
                            (DEVICE,ch,now-offset,80,b"\x50\x00\x00\x15\x12\x00\x00\x00\x01","old-"+str(ch)))
        with self.assertRaisesRegex(ValueError,"not from same session"):
            m.mark_complete(self.db,json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600}))

    def test_csv_export_contains_samples_and_no_ring_identifier(self):
        frame,now=sample()
        m.ingest(self.db,self.row(frame,now))
        csv=m.export_csv(self.db,DEVICE,now-3600)
        self.assertIn("timestamp_utc,metric,value,source",csv)
        self.assertIn("hr_bpm,65.0,history",csv)
        self.assertNotIn(DEVICE,csv)
    def test_history_count_is_retained_across_duplicate_retry(self):
        frame,now=sample()
        body=self.row(frame,now)
        m.ingest(self.db,body);m.ingest(self.db,body)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM epochs").fetchone()[0],1)

    def test_valid_spool_with_more_than_4000_frames_is_accepted(self):
        now=int(time.time())
        body=(self.row(b'\x82\xff\x00\x7d',now)+b'\n')*4001
        self.assertLess(len(body),900*1024)
        self.assertEqual(m.ingest(self.db,body),4001)

    def test_completion_cannot_reuse_marker_before_attempt_started(self):
        now=int(time.time())
        for ch,seen in ((0,now-60),(3,now)):
            self.db.execute("INSERT INTO frames VALUES(?,?,?,?,?,?)",
                            (DEVICE,ch,seen,80,b'\x50\x00\x00\x15\x12\x00\x00\x00\x01',str(ch)))
        with self.assertRaisesRegex(ValueError,'current attempt'):
            m.mark_complete(self.db,json.dumps({'device':DEVICE,'channels':[0,3],'started':now}))

    def test_short_end_marker_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'end marker'):
            m.ingest(self.db,self.row(b'\x50\x00\x00\x50',int(time.time())))

    def test_legacy_and_compact_end_markers_can_complete_sync(self):
        now=int(time.time())
        for ch,raw in ((0,bytes.fromhex('500000120c22aae4')),
                       (3,bytes.fromhex('500000120c22aae40c22acb5'))):
            body=json.dumps({'device':DEVICE,'channel':ch,'seen':now,'raw':raw.hex()}).encode()
            self.assertEqual(m.ingest(self.db,body),1)
        self.assertIsInstance(m.mark_complete(self.db,json.dumps(
            {'device':DEVICE,'channels':[0,3],'started':now})),int)

    def test_collector_refuses_example_token_at_startup(self):
        import os,subprocess
        env=dict(os.environ,RING_DB=str(Path(self.temp.name)/'startup.db'),
                 RING_TOKEN='CHANGE_TO_A_LONG_RANDOM_TOKEN',RING_PORT='0')
        try:
            result=subprocess.run(['python3',str(ROOT/'collector'/'app.py')],
                                  env=env,capture_output=True,timeout=3)
        except subprocess.TimeoutExpired:
            self.fail('collector started with the public example token')
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'RING_TOKEN',result.stderr)

class TestLocalHTTP(unittest.TestCase):
    """Exercise the actual private collector API, including token and atomicity."""
    def setUp(self):
        import threading
        self.temp=tempfile.TemporaryDirectory()
        self.old_db,self.old_token=m.DB,m.TOKEN
        m.DB=Path(self.temp.name)/"http.db"
        m.TOKEN="a-secret-token-which-is-over-twenty-characters"
        m.connect().close()
        self.server=m.ThreadingHTTPServer(("127.0.0.1",0),m.API)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.base=f"http://127.0.0.1:{self.server.server_port}"
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        m.DB,m.TOKEN=self.old_db,self.old_token
        self.temp.cleanup()
    def req(self,path,body=None,token=True):
        from urllib.request import Request,urlopen
        headers={"X-Ring-Token":m.TOKEN} if token else {}
        if body is not None:headers["Content-Type"]="application/x-ndjson"
        request=Request(self.base+path,data=body,headers=headers)
        with urlopen(request,timeout=5) as response:
            return response.status,response.read()
    def test_unauthenticated_health_and_time_only(self):
        from urllib.error import HTTPError
        self.assertEqual(self.req("/health",token=False)[0],200)
        self.assertGreater(int(self.req("/time",token=False)[1]),m.EPOCH)
        with self.assertRaises(HTTPError) as error:
            self.req("/status",token=False)
        self.assertEqual(error.exception.code,401)
    def test_atomic_batch_and_full_sync_receipt(self):
        from urllib.error import HTTPError
        frame,now=sample()
        line=json.dumps({"device":DEVICE,"channel":0,"seen":now,"raw":frame.hex()}).encode()
        bad=line[:-2]+b"xx"
        with self.assertRaises(HTTPError) as error:
            self.req("/ingest",line+b"\n"+bad+b"\n")
        self.assertEqual(error.exception.code,400)
        first=json.loads(self.req("/status")[1])
        self.assertEqual(first["device_count"],0)
        self.assertTrue(json.loads(self.req("/ingest",line)[1])["committed"])
        with self.assertRaises(HTTPError) as error:
            self.req("/complete",json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600}).encode())
        self.assertEqual(error.exception.code,400)
        for channel in (0,3):
            raw=bytes((0x82,0xff,0x00,0x7d))
            body=json.dumps({"device":DEVICE,"channel":channel,"seen":now,"raw":raw.hex()}).encode()
            self.req("/ingest",body)
        result=json.loads(self.req("/complete",json.dumps({"device":DEVICE,"channels":[0,3],"started":int(time.time())-600}).encode())[1])
        self.assertTrue(result["confirmed"])
        status=json.loads(self.req("/status")[1])
        self.assertEqual(status["devices"][DEVICE]["sync_state"],"healthy")
if __name__=="__main__":unittest.main()
