"""Ephemeral, revocable read-only browser sessions. No token in browser storage."""
import hashlib,hmac,secrets,threading,time
from http.cookies import SimpleCookie

class BrowserSessions:
    def __init__(self):
        self.sessions={};self.attempts={};self.lock=threading.Lock()
    def issue(self,key,expected,peer):
        now=time.time()
        with self.lock:
            self.attempts={ip:entry for ip,entry in self.attempts.items() if entry[0]>now-60}
            since,count=self.attempts.get(peer,(now,0))
            if count>=10:return None,429
            if len(self.attempts)>=512 and peer not in self.attempts:return None,429
            self.attempts[peer]=(since,count+1)
            if not expected or not hmac.compare_digest(key.encode(),expected.encode()):return None,401
            self.sessions={key:expires for key,expires in self.sessions.items() if expires>now}
            if len(self.sessions)>=128:return None,429
            session=secrets.token_urlsafe(32)
            self.sessions[self.digest(session)]=now+12*3600
            return session,200
    @staticmethod
    def digest(session):return hashlib.sha256(session.encode()).hexdigest()
    @staticmethod
    def parse(cookie):
        try:
            parsed=SimpleCookie();parsed.load(cookie or '')
            return parsed['oc_session'].value if 'oc_session' in parsed else ''
        except Exception:return ''
    def valid(self,cookie):
        session=self.parse(cookie)
        with self.lock:return bool(session and self.sessions.get(self.digest(session),0)>time.time())
    def revoke(self,cookie):
        with self.lock:self.sessions.pop(self.digest(self.parse(cookie)),None)

SESSIONS=BrowserSessions()
