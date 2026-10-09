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
