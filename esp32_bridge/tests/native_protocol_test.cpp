#include "ring_protocol.h"
#include <cassert>
#include <cstdio>
#include <cstring>
static bool eq(const uint8_t* p,const char* hex,size_t n){
  for(size_t i=0;i<n;i++){unsigned x=0;if(sscanf(hex+i*2,"%2x",&x)!=1||p[i]!=x)return false;}
  return true;
}
int main(){
  uint8_t digest[32];
  ring::sm3((const uint8_t*)"abc",3,digest);
  assert(eq(digest,"66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",32));
  // Two known Gen-2 SM3 challenge/response captures from upstream OpenCircuit.
  uint8_t mac[]={0xf8,0x79,0x99,0xf7,0x03,0xad},auth[6];
  ring::authResponse(mac,0xb0,auth);assert(eq(auth,"010131826700",6));
  ring::authResponse(mac,0xe5,auth);assert(eq(auth,"0101520be100",6));
  uint8_t open[9];ring::syncOpen(ring::EPOCH+0x0c2298c3,3,open);
  assert(eq(open,"02000c2298c3030100",9));
  uint8_t frame[4]={0x82,0,0,0x82};
  assert(ring::validFrame(frame,4));frame[2]=1;assert(!ring::validFrame(frame,4));
  uint8_t end[]={0x50,0,0,0x15,0x12,0,0,0,1};
  assert(ring::validFrame(end,sizeof(end))); // event entry, no XOR trailer
  uint8_t shortEnd[]={0x50,0,0,0x50};
  assert(!ring::validFrame(shortEnd,sizeof(shortEnd)));
  uint8_t legacyEnd[]={0x50,0,0,0x12,0x0c,0x22,0xaa,0xe4};
  uint8_t compactEnd[]={0x50,0,0,0x12,0x0c,0x22,0xaa,0xe4,0x0c,0x22,0xac,0xb5};
  assert(ring::validFrame(legacyEnd,sizeof(legacyEnd)));
  assert(ring::validFrame(compactEnd,sizeof(compactEnd)));
  puts("SM3 full vector + 2 Gen2 auth captures + cursor + frame checksum: PASS");
}
