"""Calendar and transport evidence views; no inferred medical or activity scores."""
from datetime import datetime,time,timedelta
from zoneinfo import ZoneInfo

def days(db,device,start,end,timezone):
    if end-start>366*86400:raise ValueError('choose at most one year')
    tz=ZoneInfo(timezone)
    day=datetime.fromtimestamp(start,tz).date()
    result=[]
    while True:
        midnight=int(datetime.combine(day,time(),tz).timestamp())
        next_midnight=int(datetime.combine(day+timedelta(days=1),time(),tz).timestamp())
        low,high=max(start,midnight),min(end,next_midnight)
        if low>=high:break
        metrics={}
        for name,count,minimum,maximum,mean,first,last in db.execute(
            'SELECT metric,COUNT(*),MIN(value),MAX(value),AVG(value),MIN(stamp),MAX(stamp) '
            'FROM metrics WHERE device=? AND stamp>=? AND stamp<? GROUP BY metric',(device,low,high)):
            sources=dict(db.execute('SELECT source,COUNT(*) FROM metrics WHERE device=? AND metric=? '
                                    'AND stamp>=? AND stamp<? GROUP BY source',(device,name,low,high)))
            metrics[name]={'count':count,'min':minimum,'max':maximum,'mean':mean,
                           'first_at':first,'last_at':last,'sources':sources}
        result.append({'date':day.isoformat(),'start':low,'end':high,'metrics':metrics})
        day+=timedelta(days=1)
    return {'timezone':timezone,'days':result}

def diagnostics(db,device):
    archive={name:db.execute(f'SELECT COUNT(*) FROM {name} WHERE device=?',(device,)).fetchone()[0]
             for name in ('frames','epochs','metrics')}
    channels={}
    for channel in (0,3):
        count,pages,empty,last=db.execute(
            'SELECT COUNT(*),COALESCE(SUM(opcode IN (71,76)),0),'
            "COALESCE(SUM(opcode=130 AND hex(substr(raw,2,1))='FF'),0),MAX(seen) "
            'FROM frames WHERE device=? AND channel=?',(device,channel)).fetchone()
        last_end=db.execute("SELECT MAX(seen) FROM frames WHERE device=? AND channel=? AND "
                            "(opcode=80 OR (opcode=130 AND hex(substr(raw,2,1))='FF'))",(device,channel)).fetchone()[0]
        channels[str(channel)]={'frames':count,'pages':pages,'empty_acks':empty,'last_seen':last,'last_end_seen':last_end}
    metrics={name:{'count':count,'first_at':first,'last_at':last,'sources':dict(db.execute(
        'SELECT source,COUNT(*) FROM metrics WHERE device=? AND metric=? GROUP BY source',(device,name)))}
        for name,count,first,last in db.execute('SELECT metric,COUNT(*),MIN(stamp),MAX(stamp) FROM metrics '
                                               'WHERE device=? GROUP BY metric',(device,))}
    syncs=[{'completed':completed,'sleep_end_seen':sleep,'day_end_seen':day}
           for completed,sleep,day in db.execute('SELECT completed,sleep_end_seen,day_end_seen FROM sync_sessions '
                                                 'WHERE device=? ORDER BY completed DESC LIMIT 20',(device,))]
    uploads=[{'committed':stamp,'received_frames':count} for stamp,count in db.execute(
        'SELECT committed,frames FROM uploads WHERE device=? ORDER BY committed DESC,id DESC LIMIT 20',(device,))]
    return {'archive':archive,'channels':channels,'metrics':metrics,'syncs':syncs,'uploads':uploads}
