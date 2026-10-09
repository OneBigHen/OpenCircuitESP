import json,time,unittest
from urllib.request import Request,urlopen
from urllib.error import HTTPError
import test_collector as fixtures
m,DEVICE=fixtures.m,fixtures.DEVICE

class TestHealthPWA(unittest.TestCase):
    def setUp(self):
        fixtures.TestLocalHTTP.setUp(self)
        m.SESSIONS=type(m.SESSIONS)()
    tearDown=fixtures.TestLocalHTTP.tearDown
    def browser(self,path,body=None,cookie=None,origin=None):
        headers={'Content-Type':'application/json','X-OpenCircuit-UI':'1'}
        if cookie:headers['Cookie']=cookie
        if origin:headers['Origin']=origin
        request=Request(self.base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
        return urlopen(request,timeout=5)
    def login(self):
        with self.browser('/auth/login',{'token':m.TOKEN}) as response:
            cookie=response.headers.get('Set-Cookie')
            self.assertIn('HttpOnly',cookie);self.assertIn('SameSite=Strict',cookie)
            self.assertNotIn(m.TOKEN,cookie)
            return cookie.split(';')[0]
    def test_public_shell_manifest_and_path_boundaries(self):
        with self.browser('/') as response:
            self.assertIn(b'OpenCircuit',response.read())
            self.assertIn("default-src 'self'",response.headers['Content-Security-Policy'])
        with self.browser('/app.webmanifest') as response:
            manifest=json.load(response);self.assertEqual(manifest['display'],'standalone')
        for path in ('/app/../app.py','/status','/overview?device='+DEVICE):
            with self.assertRaises(HTTPError):self.browser(path)
    def test_cookie_login_is_read_only_and_logout_revokes_it(self):
        cookie=self.login()
        with self.browser('/status',cookie=cookie) as response:self.assertEqual(json.load(response)['device_count'],0)
        for path in ('/ingest','/complete'):
            with self.assertRaises(HTTPError) as error:self.browser(path,{},cookie)
            self.assertEqual(error.exception.code,401)
        with self.browser('/auth/logout',{},cookie):pass
        with self.assertRaises(HTTPError) as error:self.browser('/status',cookie=cookie)
        self.assertEqual(error.exception.code,401)
    def test_cross_origin_login_rejected(self):
        with self.assertRaises(HTTPError) as error:self.browser('/auth/login',{'token':m.TOKEN},origin='https://evil.example')
        self.assertEqual(error.exception.code,403)
    def test_overview_uses_every_sample_in_range_and_previous_period(self):
        now=int(time.time());db=m.connect()
        for stamp,value in ((now-1500,50),(now-900,60),(now-300,80)):
            m.put_metric(db,DEVICE,'hr_bpm',stamp,value,'history')
        db.commit();db.close()
        with self.browser(f'/overview?device={DEVICE}&start={now-1200}&end={now}&bucket=600',cookie=self.login()) as response:
            data=json.load(response)['metrics']['hr_bpm']
        self.assertEqual(data['count'],2);self.assertEqual(data['mean'],70)
        self.assertEqual(data['previous']['mean'],50);self.assertEqual(data['latest']['value'],80)
        self.assertEqual(sum(point['count'] for point in data['series']),2)
    def test_history_pages_exact_samples_without_silently_truncating(self):
        now=int(time.time());db=m.connect()
        for n in range(6):m.put_metric(db,DEVICE,'hr_bpm',now-n*150,60+n,'history')
        db.commit();db.close();cookie=self.login()
        with self.browser(f'/history?device={DEVICE}&since={now-2000}&until={now+1}&limit=3',cookie=cookie) as response:page=json.load(response)
        self.assertTrue(page['truncated']);self.assertEqual(len(page['points']),3)
        with self.browser(f'/history?device={DEVICE}&since={now-2000}&until={now+1}&limit=3&before={page["next_before"]}',cookie=cookie) as response:older=json.load(response)
        self.assertEqual(len({p['timestamp'] for p in page['points']+older['points']}),6)

    def test_history_cursor_preserves_sources_with_identical_timestamps(self):
        now=int(time.time());db=m.connect()
        for source in ('history','status'):m.put_metric(db,DEVICE,'hr_bpm',now,60,source)
        db.commit();db.close();cookie=self.login()
        with self.browser(f'/history?device={DEVICE}&since={now-10}&until={now+1}&limit=1',cookie=cookie) as response:page=json.load(response)
        from urllib.parse import urlencode
        query=urlencode({'device':DEVICE,'since':now-10,'until':now+1,'limit':1,'before':page['next_before']})
        with self.browser('/history?'+query,cookie=cookie) as response:older=json.load(response)
        self.assertEqual({p['source'] for p in page['points']+older['points']},{'history','status'})
    def test_bad_range_is_rejected(self):
        cookie=self.login()
        for query in ('start=200&end=100','start=NaN&end=300','start=0&end=99999999999999999999999'):
            with self.assertRaises(HTTPError) as error:self.browser('/overview?device='+DEVICE+'&'+query,cookie=cookie)
            self.assertEqual(error.exception.code,400)

    def test_csv_export_supports_complete_archive_since_zero(self):
        db=m.connect();m.put_metric(db,DEVICE,'hr_bpm',int(time.time())-100,65,'history');db.commit();db.close()
        with self.browser('/export.csv?device='+DEVICE+'&since=0',cookie=self.login()) as response:
            self.assertIn(b'hr_bpm,65.0,history',response.read())

    def test_wrong_login_key_is_rejected(self):
        with self.assertRaises(HTTPError) as error:self.browser('/auth/login',{'token':'wrong'})
        self.assertEqual(error.exception.code,401)

    def test_cookie_sessions_are_secure_when_https_mode_is_enabled(self):
        from unittest.mock import patch
        with patch.dict('os.environ',{'RING_SECURE_COOKIE':'1'}):
            with self.browser('/auth/login',{'token':m.TOKEN}) as response:self.assertIn('Secure',response.headers['Set-Cookie'])

if __name__=='__main__':unittest.main()
