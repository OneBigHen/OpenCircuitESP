#include "ring_protocol.h"
#include <cassert>
#include <cstring>
#include <cstdio>
int main(){
  uint8_t d[32];ring::sm3((const uint8_t*)"abc",3,d);
  const unsigned char expected[]={0x66,0xc7,0xf0,0xf4,0x62,0xee,0xed,0xd9};
  assert(memcmp(d,expected,8)==0);
  uint8_t f[]={0x82,0,0,0x82};
  assert(ring::validFrame(f,4)); f[3]^=1; assert(!ring::validFrame(f,4));
  uint8_t open[9];ring::syncOpen(ring::EPOCH+0x12345678,3,open);
  assert(open[0]==2&&open[1]==0&&open[2]==0x12&&open[5]==0x78&&open[6]==3);
  uint8_t mac[]={0xf8,0x79,0x99,0xf7,0x03,0xad},out[6];
  ring::authResponse(mac,0xb0,out); assert(out[0]==1&&out[1]==1&&out[5]==0);
  puts("RingConn protocol tests passed");
}