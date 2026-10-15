import json,time,unittest,tempfile,sqlite3
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from urllib.error import HTTPError
from urllib.parse import urlencode
import test_pwa_api as httpfixtures
import test_collector as fixtures
m,DEVICE=fixtures.m,fixtures.DEVICE

class TestRingDayHTTP(unittest.TestCase):
    setUp=httpfixtures.TestHealthPWA.setUp
    tearDown=httpfixtures.TestHealthPWA.tearDown
    browser=httpfixtures.TestHealthPWA.browser
    login=httpfixtures.TestHealthPWA.login
    def test_daily_rollups_follow_local_dates_and_dst(self):
        tz=ZoneInfo('America/New_York')
        start=int(datetime(2026,3,8,tzinfo=tz).timestamp())
        end=int(datetime(2026,3,10,tzinfo=tz).timestamp())
        db=m.connect()
        for stamp,val in ((start,0),(start+3600,10),(end-1,20)):
            m.put_metric(db,DEVICE,'quarter_hour_steps',stamp,val,'status')
        db.commit();db.close()
        query=urlencode(dict(device=DEVICE,start=start,end=end,timezone='America/New_York'))
        with self.browser('/days?'+query,cookie=self.login()) as r:data=json.load(r)
        self.assertEqual([d['date'] for d in data['days']],['2026-03-08','2026-03-09'])
        self.assertEqual(data['days'][0]['end']-data['days'][0]['start'],23*3600)
        metric=data['days'][0]['metrics']['quarter_hour_steps']
        self.assertEqual(metric['count'],2);self.assertEqual(metric['min'],0)
        self.assertEqual(metric['mean'],5);self.assertNotIn('total',metric)
        self.assertEqual(metric['sources'],{'status':2})
    def test_daily_missing_days_and_partial_bounds_remain_explicit(self):
        start=1704067200;end=start+2*86400+3600
        db=m.connect();m.put_metric(db,DEVICE,'hr_bpm',start,60,'history');db.commit();db.close()
        with self.browser(f'/days?device={DEVICE}&start={start}&end={end}&timezone=UTC',cookie=self.login()) as r:days=json.load(r)['days']
        self.assertEqual(len(days),3);self.assertEqual(days[1]['metrics'],{})
        self.assertEqual(days[2]['end']-days[2]['start'],3600)
    def test_daily_invalid_timezone_and_excessive_range_rejected(self):
        cookie=self.login()
        for query in ('timezone=Not/AZone','start=1&end=100000000'):
            with self.assertRaises(HTTPError) as e:self.browser('/days?device='+DEVICE+'&'+query,cookie=cookie)
            self.assertEqual(e.exception.code,400)
    def test_diagnostics_partial_upload_is_not_a_completed_sync(self):
        raw,seen=fixtures.sample();db=m.connect()
        m.ingest(db,json.dumps({'device':DEVICE,'channel':0,'seen':seen,'raw':raw.hex()}).encode());db.commit();db.close()
        with self.browser('/diagnostics?device='+DEVICE,cookie=self.login()) as r:data=json.load(r)
        self.assertEqual(data['archive']['frames'],1)
        self.assertEqual(data['channels']['0']['pages'],1)
        self.assertIsNone(data['channels']['3']['last_end_seen'])
        self.assertEqual(data['syncs'],[])
        self.assertEqual(data['metrics']['hr_bpm']['count'],1)
        self.assertNotIn('raw',json.dumps(data));self.assertNotIn(m.TOKEN,json.dumps(data))
    def test_diagnostics_explicit_empty_channels_can_complete(self):
        now=int(time.time());db=m.connect()
        for ch in (0,3):
            raw=bytes.fromhex('82ff7d')
            m.ingest(db,json.dumps({'device':DEVICE,'channel':ch,'seen':now,'raw':raw.hex()}).encode())
        m.mark_complete(db,json.dumps({'device':DEVICE,'started':now,'channels':[0,3]}).encode());db.commit();db.close()
        with self.browser('/diagnostics?device='+DEVICE,cookie=self.login()) as r:data=json.load(r)
        self.assertEqual(len(data['syncs']),1)
        self.assertEqual(data['channels']['0']['empty_acks'],1)
        self.assertEqual(data['archive']['metrics'],0)
    def test_new_health_endpoints_require_auth(self):
        for path in ('/days','/diagnostics'):
            with self.assertRaises(HTTPError) as e:self.browser(path+'?device='+DEVICE)
            self.assertEqual(e.exception.code,401)

class TestTransportCounts(unittest.TestCase):
    def test_multiring_upload_counts_are_attributed_to_each_ring(self):
        with tempfile.TemporaryDirectory() as folder:
            db=m.connect(Path(folder)/'db.sqlite3');raw,seen=fixtures.sample()
            second='AA:BB:CC:DD:EE:FF'
            rows=[{'device':dev,'channel':0,'seen':seen,'raw':raw.hex()} for dev in (DEVICE,DEVICE,second)]
            m.ingest(db,b'\n'.join(json.dumps(row).encode() for row in rows));db.commit()
            counts=dict(db.execute('SELECT device,frames FROM uploads'))
            self.assertEqual(counts,{DEVICE:2,second:1});db.close()

class TestArchiveBackup(unittest.TestCase):
    def test_online_backup_is_consistent_and_does_not_overwrite(self):
        import archive_tools
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'source.db';target=Path(folder)/'backup.db'
            db=m.connect(source);m.put_metric(db,DEVICE,'hr_bpm',100,65,'history');db.commit()
            result=archive_tools.backup(source,target)
            self.assertEqual(result['integrity'],'ok')
            copy=sqlite3.connect(target);self.assertEqual(copy.execute('SELECT COUNT(*) FROM metrics').fetchone()[0],1);copy.close()
            self.assertEqual(target.stat().st_mode & 0o777,0o600)
            with self.assertRaises(FileExistsError):archive_tools.backup(source,target)
            db.close()
