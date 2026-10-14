"""Bounded chart rollups over every sample, with exact history kept separately."""
import csv,io,time

def overview(db,device,start,end,bucket):
    metrics={}
    span=end-start
    for name,count,low,high,mean,first,last in db.execute(
        'SELECT metric,COUNT(*),MIN(value),MAX(value),AVG(value),MIN(stamp),MAX(stamp) '
        'FROM metrics WHERE device=? AND stamp>=? AND stamp<? GROUP BY metric',
        (device,start,end)):
        latest=db.execute('SELECT stamp,value,source FROM metrics WHERE device=? AND metric=? '
                          'AND stamp>=? AND stamp<? ORDER BY stamp DESC LIMIT 1',
                          (device,name,start,end)).fetchone()
        prior=db.execute('SELECT COUNT(*),AVG(value) FROM metrics WHERE device=? AND metric=? '
                         'AND stamp>=? AND stamp<?',(device,name,start-span,start)).fetchone()
        series=[{'timestamp':stamp,'value':value,'min':minimum,'max':maximum,'count':n}
                for stamp,value,minimum,maximum,n in db.execute(
            'SELECT ?+CAST((stamp-?)/? AS INTEGER)*?,AVG(value),MIN(value),MAX(value),COUNT(*) '
            'FROM metrics WHERE device=? AND metric=? AND stamp>=? AND stamp<? '
            'GROUP BY CAST((stamp-?)/? AS INTEGER) ORDER BY stamp',
            (start,start,bucket,bucket,device,name,start,end,start,bucket))]
        metrics[name]={'count':count,'min':low,'max':high,'mean':mean,'first_at':first,'last_at':last,
                       'latest':{'timestamp':latest[0],'value':latest[1],'source':latest[2]},
                       'previous':{'count':prior[0],'mean':prior[1]},'series':series}
    return {'device':device,'range':{'start':start,'end':end,'bucket':bucket},'metrics':metrics,
            'generated_at':int(time.time())}

def export_chunks(db,device,start,end):
    """Stream the complete archive or selected range without a silent row limit."""
    output=io.StringIO();writer=csv.writer(output)
    writer.writerow(('timestamp_utc','metric','value','source'))
    yield output.getvalue().encode();output.seek(0);output.truncate(0)
    for index,(stamp,name,value,source) in enumerate(db.execute(
        'SELECT stamp,metric,value,source FROM metrics WHERE device=? AND stamp>=? AND stamp<? '
        'ORDER BY stamp,metric,source',(device,start,end)),1):
        writer.writerow((time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(stamp)),name,value,source))
        if index%512==0:
            yield output.getvalue().encode();output.seek(0);output.truncate(0)
    if output.tell():yield output.getvalue().encode()

HA_SERIES=('hr_bpm','hrv_rmssd_ms','spo2_pct','respiratory_rate','skin_temp_c','battery_pct','quarter_hour_steps')

def ha_dashboard(db,device,tz_name,diag_text=''):
    """One compact payload for the Home Assistant dashboard card (kept well under 64 KB)."""
    import re
    from datetime import datetime,timedelta
    from zoneinfo import ZoneInfo
    now=int(time.time());tz=ZoneInfo(tz_name)
    latest={}
    for name,stamp,value,source in db.execute(
        'SELECT metric,stamp,value,source FROM metrics m WHERE device=? AND stamp=('
        'SELECT MAX(stamp) FROM metrics WHERE device=m.device AND metric=m.metric) GROUP BY metric',(device,)):
        latest[name]={'v':value,'t':stamp,'src':source}
    series={}
    for name in HA_SERIES:
        rows=db.execute('SELECT CAST(stamp/900 AS INTEGER)*900,AVG(value),MIN(value),MAX(value) FROM metrics '
                        'WHERE device=? AND metric=? AND stamp>=? GROUP BY CAST(stamp/900 AS INTEGER) ORDER BY 1',
                        (device,name,now-86400)).fetchall()
        series[name]=[[t,round(a,2),round(lo,2),round(hi,2)] for t,a,lo,hi in rows]
    # Steps: the descriptor carries the running count for the current quarter hour; keep each bucket's max.
    steps_today=0
    midnight=int(datetime.now(tz).replace(hour=0,minute=0,second=0,microsecond=0).timestamp())
    for (peak,) in db.execute('SELECT MAX(value) FROM metrics WHERE device=? AND metric=? AND stamp>=? '
                              'GROUP BY CAST(stamp/900 AS INTEGER)',(device,'quarter_hour_steps',midnight)):
        steps_today+=int(peak or 0)
    days=[]
    day0=datetime.now(tz).replace(hour=0,minute=0,second=0,microsecond=0)
    for back in range(13,-1,-1):
        start=day0-timedelta(days=back);s=int(start.timestamp());e=int((start+timedelta(days=1)).timestamp())
        row={'date':start.strftime('%Y-%m-%d')}
        for name,n,lo,hi,mean in db.execute('SELECT metric,COUNT(*),MIN(value),MAX(value),AVG(value) FROM metrics '
                                            'WHERE device=? AND stamp>=? AND stamp<? GROUP BY metric',(device,s,e)):
            row[name]=[n,round(lo,2),round(hi,2),round(mean,2)]
        row['steps']=sum(int(p or 0) for (p,) in db.execute(
            'SELECT MAX(value) FROM metrics WHERE device=? AND metric=? AND stamp>=? AND stamp<? '
            'GROUP BY CAST(stamp/900 AS INTEGER)',(device,'quarter_hour_steps',s,e)))
        days.append(row)
    # Battery drain while off the charger, over the last 6 h (percent per hour; None if charging/too little data).
    pts=db.execute("SELECT b.stamp,b.value FROM metrics b WHERE b.device=? AND b.metric='battery_pct' AND b.stamp>=? "
                   "AND NOT EXISTS (SELECT 1 FROM metrics c WHERE c.device=b.device AND c.metric='charging' "
                   "AND c.stamp=b.stamp AND c.value=1) ORDER BY b.stamp",(device,now-6*3600)).fetchall()
    drain=None
    if len(pts)>=2 and pts[-1][0]-pts[0][0]>=1800 and pts[-1][1]<=pts[0][1]:
        drain=round((pts[0][1]-pts[-1][1])/((pts[-1][0]-pts[0][0])/3600),2)
    # Bridge link log from the ESP32 diagnostics: connects (RSSI) and drops (seconds held, reason).
    links=[]
    for m in re.finditer(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \| Ring (connected, signal (-?\d+) dBm|link dropped after (\d+)s \(reason (0x[0-9A-F]+))',
                         diag_text,re.M):
        when=int(datetime.strptime(m.group(1),'%Y-%m-%d %H:%M:%S').replace(tzinfo=ZoneInfo('UTC')).timestamp())
        if m.group(3):links.append({'t':when,'event':'connect','rssi':int(m.group(3))})
        else:links.append({'t':when,'event':'drop','held_s':int(m.group(4)),'reason':m.group(5)})
    fw=re.findall(r'fw=(\S+)',diag_text[-4000:])
    frame=db.execute('SELECT MAX(seen) FROM frames WHERE device=?',(device,)).fetchone()[0]
    sync=db.execute('SELECT MAX(completed) FROM sync_sessions WHERE device=?',(device,)).fetchone()[0]
    return {'device':device,'generated_at':now,'timezone':tz_name,'latest':latest,'series_24h':series,
            'steps_today':steps_today,'days':days,'battery_drain_pct_per_h':drain,
            'bridge':{'firmware':fw[-1] if fw else None,'last_frame':frame,'last_full_sync':sync,'links':links[-40:]}}
