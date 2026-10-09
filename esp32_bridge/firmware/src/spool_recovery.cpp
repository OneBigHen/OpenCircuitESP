#include "spool_recovery.h"
#include <cerrno>
#include <cstdio>
#include <string>
#include <unistd.h>

namespace ring {
static bool syncClose(FILE* file) {
  bool ok=fflush(file)==0;
  if(ok)ok=fsync(fileno(file))==0;
  return fclose(file)==0&&ok;
}
bool recoverSpool(const char* path) {
  FILE* source=fopen(path,"rb");
  if(!source)return errno==ENOENT;
  if(fseek(source,0,SEEK_END)!=0){fclose(source);return false;}
  long size=ftell(source);
  if(size<0){fclose(source);return false;}
  if(size==0){fclose(source);return true;}
  if(fseek(source,size-1,SEEK_SET)!=0){fclose(source);return false;}
  if(fgetc(source)=='\n'){fclose(source);return true;}

  // Only an incomplete last record can exist: firmware stops appending/ACKing
  // on its first write failure. Search backwards without loading the backlog.
  long prefix=0,end=size;
  char buffer[512];
  while(end>0&&!prefix){
    long start=end>long(sizeof(buffer))?end-long(sizeof(buffer)):0;
    size_t length=size_t(end-start);
    if(fseek(source,start,SEEK_SET)!=0||fread(buffer,1,length,source)!=length){
      fclose(source);return false;
    }
    for(size_t i=length;i>0;--i)if(buffer[i-1]=='\n'){prefix=start+long(i);break;}
    end=start;
  }
  // Keep unACKed bytes as evidence; never include them in an ingest request.
  std::string tail=std::string(path)+".torn",temp=std::string(path)+".recovering";
  FILE* evidence=fopen(tail.c_str(),"ab");
  if(!evidence){fclose(source);return false;}
  bool ok=fseek(source,prefix,SEEK_SET)==0;
  long remaining=size-prefix;
  while(ok&&remaining>0){
    size_t n=remaining>long(sizeof(buffer))?sizeof(buffer):size_t(remaining);
    ok=fread(buffer,1,n,source)==n&&fwrite(buffer,1,n,evidence)==n;
    remaining-=long(n);
  }
  ok=syncClose(evidence)&&ok;
  if(!ok){fclose(source);return false;}
  FILE* recovered=fopen(temp.c_str(),"wb");
  if(!recovered){fclose(source);return false;}
  ok=fseek(source,0,SEEK_SET)==0;remaining=prefix;
  while(ok&&remaining>0){
    size_t n=remaining>long(sizeof(buffer))?sizeof(buffer):size_t(remaining);
    ok=fread(buffer,1,n,source)==n&&fwrite(buffer,1,n,recovered)==n;
    remaining-=long(n);
  }
  fclose(source);ok=syncClose(recovered)&&ok;
  if(!ok)return false;
  return rename(temp.c_str(),path)==0;
}
}
