#include "spool_recovery.h"
#include <cassert>
#include <cstdio>
#include <string>
#include <unistd.h>

static void writeFile(const std::string& path, const std::string& data) {
  FILE* f=fopen(path.c_str(),"wb");assert(f);
  assert(fwrite(data.data(),1,data.size(),f)==data.size());assert(fclose(f)==0);
}
static std::string readFile(const std::string& path) {
  FILE* f=fopen(path.c_str(),"rb");assert(f);
  std::string data;int c;while((c=fgetc(f))!=EOF)data+=char(c);
  fclose(f);return data;
}
int main() {
  char directory[]="/tmp/ringspool-XXXXXX";assert(mkdtemp(directory));
  std::string path=std::string(directory)+"/pending.ndjson";
  assert(ring::recoverSpool(path.c_str())); // no backlog
  std::string complete="{\"raw\":\"first\"}\n{\"raw\":\"second\"}\n";
  writeFile(path,complete);
  assert(ring::recoverSpool(path.c_str()));assert(readFile(path)==complete);
  writeFile(path,complete+"{\"raw\":\"torn");
  assert(ring::recoverSpool(path.c_str()));assert(readFile(path)==complete);
  assert(readFile(path+".torn")=="{\"raw\":\"torn");
  // Simulate a crash during recovery: original survives, partial temp ignored.
  writeFile(path,complete+"fragment");writeFile(path+".recovering","partial");
  assert(ring::recoverSpool(path.c_str()));assert(readFile(path)==complete);
  writeFile(path,"only partial first record");
  assert(ring::recoverSpool(path.c_str()));assert(readFile(path).empty());
  assert(ring::recoverSpool(path.c_str()));
  unlink(path.c_str());unlink((path+".torn").c_str());rmdir(directory);
  puts("Spool complete records, torn tail, interrupted recovery, empty prefix: PASS");
}
