"""Consistent SQLite online backups and integrity checks. Run on the owning host."""
import argparse,json,os,sqlite3,tempfile
from pathlib import Path
from contextlib import closing

def check(database):
    path=Path(database).resolve()
    with closing(sqlite3.connect(path.as_uri()+'?mode=ro',uri=True)) as db:
        integrity='; '.join(row[0] for row in db.execute('PRAGMA integrity_check'))
        return {'integrity':integrity,'counts':{table:db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]
                                               for table in ('frames','epochs','metrics','sync_sessions')}}

def backup(database,output):
    source,target=Path(database).resolve(),Path(output).resolve()
    if target.exists():raise FileExistsError('backup destination already exists')
    target.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.opencircuit-backup-',suffix='.db',dir=target.parent)
    os.close(fd);temp=Path(name)
    try:
        with closing(sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)) as src,closing(sqlite3.connect(temp)) as dest:
            src.backup(dest,pages=256)
        result=check(temp)
        if result['integrity']!='ok':raise ValueError('backup integrity check failed')
        with temp.open('rb') as data:os.fsync(data.fileno())
        os.link(temp,target) # Atomic publication that never replaces an existing file.
        return result
    finally:temp.unlink(missing_ok=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('check','backup'))
    parser.add_argument('--database',required=True)
    parser.add_argument('--output')
    args=parser.parse_args()
    if args.action=='backup' and not args.output:parser.error('backup requires --output')
    try:
        result=backup(args.database,args.output) if args.action=='backup' else check(args.database)
        print(json.dumps(result));return 0 if result['integrity']=='ok' else 1
    except (OSError,sqlite3.Error,ValueError) as error:
        parser.exit(1,str(error)+'\n')
if __name__=='__main__':raise SystemExit(main())
