"""Local-only RingConn Gen 2 collector. No external dependencies or cloud APIs.
Protocol attribution: https://github.com/perezjuanj/OpenCircuit/docs/PROTOCOL.md
Stores raw wire evidence BEFORE exposing conservatively decoded measurements.
"""
import csv, hashlib, hmac, io, json, os, re, sqlite3, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from browser_auth import SESSIONS
from health_views import overview,export_chunks

DB=Path(os.getenv("RING_DB","/data/ringconn.db"))
TOKEN=os.getenv("RING_TOKEN","")
VIEW_TOKEN=os.getenv("RING_VIEW_TOKEN","")
STATIC=Path(__file__).resolve().parent/'web'
ASSETS={'/':'index.html','/index.html':'index.html','/app.css':'app.css',
        '/app.js':'app.js','/model.mjs':'model.mjs','/sw.js':'sw.js',
        '/app.webmanifest':'app.webmanifest','/icon-192.png':'icon-192.png',
        '/icon-512.png':'icon-512.png','/apple-touch-icon.png':'apple-touch-icon.png'}
CSP="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
EPOCH=1577793600
DEVICE=re.compile(r"^(?:[A-F0-9]{2}:){5}[A-F0-9]{2}$")
METRICS={"hr_bpm","hrv_rmssd_ms","spo2_pct","respiratory_rate","battery_pct",
         "battery_mv","skin_temp_c","case_battery_pct","quarter_hour_steps","charging"}
MAX_BYTES=2*1024*1024

def connect(path=None):
    path=Path(path or DB)
    path.parent.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(path,timeout=30)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS frames(
      device TEXT NOT NULL, channel INTEGER NOT NULL, seen INTEGER NOT NULL,
      opcode INTEGER NOT NULL, raw BLOB NOT NULL, digest TEXT NOT NULL,
      UNIQUE(device,channel,seen,digest));
    CREATE TABLE IF NOT EXISTS epochs(
      device TEXT NOT NULL, channel INTEGER NOT NULL, kind TEXT NOT NULL,
      counter INTEGER NOT NULL, stamp INTEGER NOT NULL, subtype INTEGER, raw BLOB NOT NULL,
      PRIMARY KEY(device,channel,kind,counter));
    CREATE TABLE IF NOT EXISTS metrics(
      device TEXT NOT NULL, metric TEXT NOT NULL, stamp INTEGER NOT NULL,
      value REAL NOT NULL, source TEXT NOT NULL,
      PRIMARY KEY(device,metric,stamp,source));
    CREATE TABLE IF NOT EXISTS uploads(
      id INTEGER PRIMARY KEY, device TEXT NOT NULL, committed INTEGER NOT NULL,
      frames INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS metrics_by_time ON metrics(device,metric,stamp);
    CREATE TABLE IF NOT EXISTS sync_sessions(
      device TEXT NOT NULL, completed INTEGER NOT NULL, sleep_end_seen INTEGER NOT NULL,
      day_end_seen INTEGER NOT NULL, PRIMARY KEY(device,completed));
    """)
    # Preserve data from earlier prototype databases: repeated identical status
    # frames at different times must not disappear from the timeline.
    prior=db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='frames'").fetchone()
    if prior and "UNIQUE(device,channel,digest)" in prior[0].replace(" ", ""):
        db.executescript("""
        BEGIN IMMEDIATE;
        ALTER TABLE frames RENAME TO frames_before_timestamp_key;
        CREATE TABLE frames(
          device TEXT NOT NULL, channel INTEGER NOT NULL, seen INTEGER NOT NULL,
          opcode INTEGER NOT NULL, raw BLOB NOT NULL, digest TEXT NOT NULL,
          UNIQUE(device,channel,seen,digest));
        INSERT OR IGNORE INTO frames SELECT * FROM frames_before_timestamp_key;
        DROP TABLE frames_before_timestamp_key;
        COMMIT;
        """)
    return db

def checksum(data):
    v=0
    for b in data:v^=b
    return v

def timestamp_from_counter(low,seen):
    # Nearest high byte heuristic for the 24-bit epoch counter. Accurate for
    # ordinary short backlogs, but inspect 0x50 raw cursor for very old data.
    cursor=max(0,seen-EPOCH)
    base=(cursor&~0xffffff)|low
    return min((k for k in (base-0x1000000,base,base+0x1000000) if k>=0),
               key=lambda k:abs(k-cursor))+EPOCH

def put_metric(db,device,name,stamp,value,source):
    if value is not None:
        db.execute("INSERT OR IGNORE INTO metrics VALUES(?,?,?,?,?)",
                   (device,name,stamp,float(value),source))

def parse_status(db,device,data,seen):
    if len(data)<19:return
    if 1<=data[1]<=100:put_metric(db,device,"battery_pct",seen,data[1],"status")
    put_metric(db,device,"charging",seen,int(data[2]==4),"status")
    put_metric(db,device,"quarter_hour_steps",seen,int.from_bytes(data[4:6],"big"),"status")
    a,b=int.from_bytes(data[6:8],"big"),int.from_bytes(data[8:10],"big")
    if 150<=a<=500 and 150<=b<=500:
        put_metric(db,device,"skin_temp_c",seen,(a+b)/20,"status")
    mv=int.from_bytes(data[14:16],"big")
    if 2500<=mv<=4600:put_metric(db,device,"battery_mv",seen,mv,"status")
    if data[17]!=255 and (data[17]&127)<=100:
        put_metric(db,device,"case_battery_pct",seen,data[17]&127,"status")

def parse_page(db,device,channel,data,seen):
    kind,width=("activity",23) if data[0]==0x4c else ("optical",47)
    if len(data)<4 or data[1]!=0 or (len(data)-4)%width:return
    for offset in range(3,len(data)-1,width):
        rec=data[offset:offset+width]
        if len(rec)!=width or rec[0]!=0x0c:continue
        stamp=timestamp_from_counter(int.from_bytes(rec[1:4],"big"),seen)
        db.execute("INSERT OR IGNORE INTO epochs VALUES(?,?,?,?,?,?,?)",
                   (device,channel,kind,stamp-EPOCH,stamp,rec[8] if width==23 else None,rec))
        if width==47:continue # not pulse-resolution PPG
        idle=(rec[4:8]==b'\x05\x00\x0c\x00' and rec[9]==10 and
              rec[10:15]==b'\x01'*5 and rec[15:22]==b'\x00'*7)
        if idle:continue
        activity=rec[8] in (0x11,0x12,0x13)
        if 30<=rec[4]<=220:put_metric(db,device,"hr_bpm",stamp,rec[4],"history")
        # Daytime HRV and RR can be motion-contaminated; start with sleep-vitals.
        if not activity:
            if 1<=rec[5]<=200:put_metric(db,device,"hrv_rmssd_ms",stamp,rec[5],"history")
            if 40<=rec[7]<=240:put_metric(db,device,"respiratory_rate",stamp,rec[7]/8,"history")
            if 70<=rec[8]<=100:put_metric(db,device,"spo2_pct",stamp,rec[8],"history")

def ingest(db,body):
    if len(body)>MAX_BYTES:raise ValueError("payload too large")
    count=0;devices=set()
    for idx,line in enumerate(body.splitlines(),1):
        if not line.strip():continue
        # MAX_BYTES already bounds work. Small frames can exceed 4,000 lines
        # inside a valid 900 KiB firmware spool; rejecting them wedges retries.
        try:
            row=json.loads(line)
            dev=str(row["device"]).upper()
            ch=int(row["channel"]);seen=int(row["seen"])
            raw=bytes.fromhex(row["raw"])
        except (ValueError,TypeError,KeyError,AttributeError) as exc:
            raise ValueError(f"invalid row {idx}") from exc
        if(not DEVICE.fullmatch(dev) or ch not in (0,3) or
           not EPOCH<seen<int(time.time())+86400 or not 3<=len(raw)<=512):
            raise ValueError(f"invalid device/channel/time at {idx}")
        if raw[0]!=0x50 and checksum(raw[:-1])!=raw[-1]:
            raise ValueError(f"frame checksum at {idx}")
        if raw[0]==0x50 and (raw[1]!=0 or not (
                (len(raw)>=9 and (len(raw)-3)%6==0) or
                (len(raw) in (8,12) and raw[2]==0))):
            raise ValueError(f"invalid end marker at {idx}")
        digest=hashlib.sha256(raw).hexdigest()
        db.execute("INSERT OR IGNORE INTO frames VALUES(?,?,?,?,?,?)",
                   (dev,ch,seen,raw[0],raw,digest))
        if raw[0] in (0x10,0x87):parse_status(db,dev,raw,seen)
        if raw[0] in (0x47,0x4c):parse_page(db,dev,ch,raw,seen)
        devices.add(dev);count+=1
    for dev in devices:
        db.execute("INSERT INTO uploads(device,committed,frames) VALUES(?,?,?)",
                   (dev,int(time.time()),count))
    return count

def mark_complete(db,body):
    """Confirm BOTH history channels have recent persisted end markers.
    A frame upload alone never proves a full sync happened.
    """
    try:
        payload=json.loads(body)
        device=str(payload["device"]).upper()
        started=int(payload["started"])
        if not DEVICE.fullmatch(device) or payload["channels"] != [0,3]:
            raise ValueError("invalid device or channel set")
    except (ValueError,KeyError,TypeError,AttributeError) as exc:
        raise ValueError("invalid completion request") from exc
    markers=[]
    now=int(time.time())
    if not now-1800<=started<=now+60:
        raise ValueError("invalid current attempt start time")
    for channel in (0,3):
        found=db.execute(
            """SELECT MAX(seen) FROM frames
               WHERE device=? AND channel=? AND
               ((opcode=80 AND ((length(raw)>=9 AND (length(raw)-3)%6=0)
                   OR (length(raw) IN (8,12) AND hex(substr(raw,3,1))='00'))
                 AND hex(substr(raw,2,1))='00')
                OR (opcode=130 AND hex(substr(raw,2,1))='FF'))""",
            (device,channel)).fetchone()[0]
        if found is None or not now-86400<=found<=now+60:
            raise ValueError(f"missing recent end marker or empty-history ACK for channel {channel}")
        markers.append(found)
    if abs(markers[0]-markers[1])>1800:
        raise ValueError("channel end markers not from same session")
    if any(found<started for found in markers):
        raise ValueError("end marker predates current attempt")
    db.execute("INSERT OR IGNORE INTO sync_sessions VALUES(?,?,?,?)",
               (device,now,markers[0],markers[1]))
    return now

def status(db):
    result={}
    for dev,when in db.execute("SELECT device,MAX(seen) FROM frames GROUP BY device"):
        item={"device":dev,"last_frame":when}
        for key,t,v in db.execute("SELECT metric,stamp,value FROM metrics WHERE device=? ORDER BY stamp DESC",(dev,)):
            if key not in item:item[key]=v;item[key+"_at"]=t
        item["frame_count"]=db.execute("SELECT COUNT(*) FROM frames WHERE device=?",(dev,)).fetchone()[0]
        item["epoch_count"]=db.execute("SELECT COUNT(*) FROM epochs WHERE device=? AND kind='activity'",(dev,)).fetchone()[0]
        item["last_upload"]=db.execute("SELECT MAX(committed) FROM uploads WHERE device=?",(dev,)).fetchone()[0]
        complete=db.execute("SELECT MAX(completed) FROM sync_sessions WHERE device=?",(dev,)).fetchone()[0]
        item["last_complete_sync"]=complete
        item["sync_state"]="healthy" if complete and (int(time.time())-complete)<36*3600 else "stale_or_never"
        item["last_frame_age_seconds"]=max(0,int(time.time())-when)
        result[dev]=item
    return {"device_count":len(result),"devices":result}

def export_csv(db,device,since,limit=100000):
    """Authenticated, chronological, measured samples for off-platform backups."""
    out=io.StringIO()
    writer=csv.writer(out)
    writer.writerow(("timestamp_utc","metric","value","source"))
    for stamp,name,value,source in db.execute(
        "SELECT stamp,metric,value,source FROM metrics WHERE device=? AND stamp>=? "
        "ORDER BY stamp ASC,metric ASC LIMIT ?",(device,since,limit)):
        writer.writerow((time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(stamp)),name,value,source))
    return out.getvalue()

class API(BaseHTTPRequestHandler):
    def security_headers(self):
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',CSP)
        self.send_header('Cache-Control','no-store')
    def response(self,code,value,ctype="application/json",headers=None):
        b=value.encode() if isinstance(value,str) else value
        self.send_response(code)
        self.send_header("Content-Type",ctype);self.send_header("Content-Length",str(len(b)))
        self.security_headers()
        for key,val in (headers or {}).items():self.send_header(key,val)
        self.end_headers()
        self.wfile.write(b)
    def authorized(self,read_only=False):
        token=self.headers.get('X-Ring-Token','')
        token_ok=bool(TOKEN and hmac.compare_digest(token.encode(),TOKEN.encode()))
        if not token_ok and not (read_only and SESSIONS.valid(self.headers.get('Cookie'))):
            self.response(401,b'{"error":"unauthorized"}');return False
        return True
    def do_GET(self):
        p=urlparse(self.path)
        if p.path in ASSETS:
            file=STATIC/ASSETS[p.path]
            if not file.is_file():return self.response(404,b'{"error":"asset missing"}')
            types={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8',
                   '.js':'text/javascript; charset=utf-8','.mjs':'text/javascript; charset=utf-8',
                   '.webmanifest':'application/manifest+json','.png':'image/png'}
            return self.response(200,file.read_bytes(),types[file.suffix])
        if p.path=="/health":return self.response(200,b'{"ok":true}')
        if p.path=="/time":return self.response(200,str(int(time.time())),"text/plain")
        if not self.authorized(read_only=True):return
        db=connect()
        try:
            if p.path=="/status":return self.response(200,json.dumps(status(db)))
            if p.path not in ("/history","/export.csv","/overview"):
                return self.response(404,b'{"error":"not found"}')
            args=parse_qs(p.query)
            dev=args.get("device",[""])[0].upper();kind=args.get("metric",["hr_bpm"])[0]
            if not DEVICE.fullmatch(dev) or (p.path=="/history" and kind not in METRICS):
                return self.response(400,b'{"error":"invalid query"}')
            now=int(time.time())
            since=int(args.get('start',args.get('since',[str(now-86400)]))[0])
            until=int(args.get('end',args.get('until',[str(now+1)]))[0])
            if not 0<=since<until<=now+86400:
                raise ValueError('invalid range')
            if p.path=='/overview':
                if until-since>10*366*86400:raise ValueError('range too long')
                bucket=max(1,int(args.get('bucket',['900'])[0]),(until-since+599)//600)
                return self.response(200,json.dumps(overview(db,dev,since,until,bucket)))
            if p.path=="/export.csv":
                self.send_response(200);self.send_header('Content-Type','text/csv; charset=utf-8')
                self.send_header('Content-Disposition','attachment; filename="opencircuit-measurements.csv"')
                self.send_header('Connection','close');self.security_headers();self.end_headers()
                for chunk in export_chunks(db,dev,since,until):self.wfile.write(chunk)
                self.close_connection=True;return
            limit=min(5000,max(1,int(args.get("limit",["1500"])[0])))
            cursor=args.get('before',[str(until)])[0].split(':',1)
            before=int(cursor[0]);source=cursor[1] if len(cursor)==2 else ''
            if source and source not in ('history','status'):raise ValueError('invalid cursor')
            rows=db.execute("SELECT stamp,value,source FROM metrics WHERE device=? AND metric=? AND stamp>=? AND stamp<? AND (stamp<? OR (stamp=? AND source<?)) ORDER BY stamp DESC,source DESC LIMIT ?",
                            (dev,kind,since,until,before,before,source,limit+1)).fetchall()
            truncated=len(rows)>limit;rows=rows[:limit]
            return self.response(200,json.dumps({"device":dev,"metric":kind,"points":[
                {"timestamp":t,"value":v,"source":source} for t,v,source in reversed(rows)],
                'truncated':truncated,'next_before':f'{rows[-1][0]}:{rows[-1][2]}' if truncated else None}))
        except (ValueError,OverflowError):
            return self.response(400,b'{"error":"bad query"}')
        finally:db.close()
    def do_POST(self):
        if self.path in ('/auth/login','/auth/logout'):return self.browser_auth()
        if self.path not in ("/ingest","/complete"):
            return self.response(404,b'{"error":"not found"}')
        if not self.authorized():return
        try:n=int(self.headers.get("Content-Length","-1"))
        except ValueError:n=-1
        if n<0 or n>(4096 if self.path=="/complete" else MAX_BYTES):
            return self.response(413,b'{"error":"payload too large"}')
        body=self.rfile.read(n);db=connect()
        try:
            db.execute("BEGIN IMMEDIATE")
            if self.path=="/complete":
                timestamp=mark_complete(db,body)
                db.commit()
                return self.response(200,json.dumps({"confirmed":True,"completed":timestamp}))
            count=ingest(db,body)
            db.commit() # HTTP 200 is returned ONLY after this commit.
            return self.response(200,json.dumps({"committed":True,"received":count}))
        except (ValueError,sqlite3.Error) as exc:
            db.rollback()
            return self.response(400,json.dumps({"committed":False,"error":str(exc)}))
        finally:db.close()
    def browser_auth(self):
        origin=self.headers.get('Origin')
        if self.headers.get('X-OpenCircuit-UI')!='1' or (origin and urlparse(origin).netloc!=self.headers.get('Host')):
            return self.response(403,b'{"error":"same-origin browser request required"}')
        secure='; Secure' if os.getenv('RING_SECURE_COOKIE','1')!='0' else ''
        if self.path=='/auth/logout':
            SESSIONS.revoke(self.headers.get('Cookie'))
            return self.response(200,b'{"ok":true}',headers={'Set-Cookie':'oc_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict'+secure})
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=2048:raise ValueError('length')
            data=json.loads(self.rfile.read(length));key=data['token']
            if not isinstance(key,str):raise ValueError('key')
        except (ValueError,KeyError,TypeError):return self.response(400,b'{"error":"invalid login"}')
        session,code=SESSIONS.issue(key,VIEW_TOKEN or TOKEN,self.client_address[0])
        if code!=200:return self.response(code,b'{"error":"access key rejected or too many attempts"}')
        return self.response(200,b'{"ok":true}',headers={'Set-Cookie':f'oc_session={session}; Path=/; Max-Age=43200; HttpOnly; SameSite=Strict'+secure})
    def log_message(self,fmt,*args):
        # Access logs intentionally omit query strings (device IDs and ranges).
        print('[ringconn]',self.command,urlparse(self.path).path,flush=True)

if __name__=="__main__":
    if len(TOKEN)<20 or TOKEN.startswith("CHANGE_"):
        raise SystemExit("RING_TOKEN must be a private random token of at least 20 characters")
    if VIEW_TOKEN and (len(VIEW_TOKEN)<20 or VIEW_TOKEN.startswith('CHANGE_')):
        raise SystemExit('RING_VIEW_TOKEN must be a private random token of at least 20 characters')
    db=connect();db.close()
    ThreadingHTTPServer((os.getenv("RING_HOST","0.0.0.0"),int(os.getenv("RING_PORT","8765"))),API).serve_forever()
