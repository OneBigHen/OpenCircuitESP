// Independently implemented from perezjuanj/OpenCircuit docs/PROTOCOL.md.
#include "ring_protocol.h"
#include <cstring>
namespace ring {
uint8_t xorChecksum(const uint8_t* d,size_t len) { uint8_t x=0;for(size_t i=0;i<len;i++)x^=d[i];return x; }
bool validFrame(const uint8_t* d,size_t len) {
  if(len<3)return false;
  // Cursor/event-log end report: 3-byte header, whole 6-byte entries, NO XOR.
  if(d[0]==0x50)return d[1]==0&&len>=9&&(len-3)%6==0;
  return xorChecksum(d,len-1)==d[len-1];
}
static inline uint32_t rotl(uint32_t a,unsigned n) {n&=31;return n?((a<<n)|(a>>(32-n))):a;}
static inline uint32_t p0(uint32_t x) {return x^rotl(x,9)^rotl(x,17);}
static inline uint32_t p1(uint32_t x) {return x^rotl(x,15)^rotl(x,23);}
void sm3(const uint8_t* input,size_t len,uint8_t out[32]) {
  if(len>55){memset(out,0,32);return;}
  uint8_t buf[64]={}; memcpy(buf,input,len);buf[len]=0x80;
  const uint64_t bits=(uint64_t)len*8;
  for(int i=0;i<8;i++)buf[56+i]=(uint8_t)(bits>>(56-8*i));
  uint32_t v[8]={0x7380166f,0x4914b2b9,0x172442d7,0xda8a0600,
                 0xa96f30bc,0x163138aa,0xe38dee4d,0xb0fb0e4e};
  uint32_t w[68],w1[64];
  for(int i=0;i<16;i++)w[i]=((uint32_t)buf[4*i]<<24)|((uint32_t)buf[4*i+1]<<16)|((uint32_t)buf[4*i+2]<<8)|buf[4*i+3];
  for(int i=16;i<68;i++)w[i]=p1(w[i-16]^w[i-9]^rotl(w[i-3],15))^rotl(w[i-13],7)^w[i-6];
  for(int i=0;i<64;i++)w1[i]=w[i]^w[i+4];
  uint32_t a=v[0],b=v[1],c=v[2],d=v[3],e=v[4],f=v[5],g=v[6],h=v[7];
  for(int j=0;j<64;j++) {
    uint32_t t=j<16?0x79cc4519:0x7a879d8a;
    uint32_t ss1=rotl(rotl(a,12)+e+rotl(t,j%32),7),ss2=ss1^rotl(a,12);
    uint32_t ff=j<16?(a^b^c):((a&b)|(a&c)|(b&c));
    uint32_t gg=j<16?(e^f^g):((e&f)|(~e&g));
    uint32_t tt1=ff+d+ss2+w1[j],tt2=gg+h+ss1+w[j];
    d=c;c=rotl(b,9);b=a;a=tt1;h=g;g=rotl(f,19);f=e;e=p0(tt2);
  }
  uint32_t words[8]={v[0]^a,v[1]^b,v[2]^c,v[3]^d,v[4]^e,v[5]^f,v[6]^g,v[7]^h};
  for(int i=0;i<8;i++){out[4*i]=words[i]>>24;out[4*i+1]=words[i]>>16;out[4*i+2]=words[i]>>8;out[4*i+3]=words[i];}
}
void authResponse(const uint8_t mac[6],uint8_t challenge,uint8_t out[6]){
  uint8_t msg[2]={static_cast<uint8_t>(mac[3]^mac[4]^mac[5]),challenge},digest[32];
  sm3(msg,2,digest);out[0]=1;out[1]=1;out[2]=digest[29];out[3]=digest[30];out[4]=digest[31];out[5]=0;
}
void syncOpen(uint64_t utc,uint8_t channel,uint8_t out[9]){
  uint32_t cursor=utc>EPOCH?static_cast<uint32_t>(utc-EPOCH):0;
  out[0]=2;out[1]=0;out[2]=cursor>>24;out[3]=cursor>>16;out[4]=cursor>>8;out[5]=cursor;
  out[6]=channel;out[7]=1;out[8]=0;
}
}
