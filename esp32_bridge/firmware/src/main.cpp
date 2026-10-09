#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include <sys/time.h>
#include <time.h>
#include "secrets.h"
#include "ring_protocol.h"

// RingConn Gen 2 BLE central and local flash spool. Protocol source:
// OpenCircuit/docs/PROTOCOL.md, RingAuth.swift, RingSession.swift.
// Never ACK a history page until its bytes are durably written to flash.
// NOT YET HARDWARE-VALIDATED. Preserve the official app until an A/B sync works.
namespace {
const char *SPOOL="/pending.ndjson";
constexpr size_t MAX_SPOOL=900*1024;
const uint8_t STATUS[]={0x01,0x00,0x00};
const uint8_t FETCH[]={0x07,0x00,0x00};
const uint8_t STOP[]={0xd0,0x00,0x00};
constexpr uint32_t RETRY_MS=15UL*60UL*1000UL;
struct Packet { uint16_t length; uint8_t bytes[512]; };
QueueHandle_t inbox=nullptr;
NimBLEClient* client=nullptr;
NimBLERemoteCharacteristic* writer=nullptr;
volatile bool packetDropped=false;
bool failed=false;
uint8_t ringMAC[6]={};
String ringID;
uint8_t channel=0;
uint32_t pages=0,lastPage=0,nextAttempt=0;
bool sawEnd=false,sawEmpty=false,authReplied=false;
time_t lastSuccess=0;

String hexdump(const uint8_t* p,size_t n){
  constexpr char lut[]="0123456789abcdef";
  String s;s.reserve(n*2+1);
  for(size_t i=0;i<n;i++){s+=lut[p[i]>>4];s+=lut[p[i]&15];}
  return s;
}
String macText(const uint8_t b[6]){
  char s[18];snprintf(s,sizeof(s),"%02X:%02X:%02X:%02X:%02X:%02X",b[0],b[1],b[2],b[3],b[4],b[5]);
  return String(s);
}
bool systemIDMac(const std::string &s,uint8_t out[6]){
  if(s.size()==6){memcpy(out,s.data(),6);return true;}
  if(s.size()!=8)return false;
  auto *p=reinterpret_cast<const uint8_t*>(s.data());
  if(p[3]==0xff&&p[4]==0xfe){memcpy(out,p,3);memcpy(out+3,p+5,3);return true;}
  if(p[3]==0xfe&&p[4]==0xff){
    for(int i=0;i<3;i++){out[i]=p[7-i];out[i+3]=p[2-i];}
    return true;
  }
  return false;
}
void notify(NimBLERemoteCharacteristic*,uint8_t* p,size_t len,bool){
  if(!inbox||!len||len>512){packetDropped=true;return;}
  Packet packet{};packet.length=len;memcpy(packet.bytes,p,len);
  if(xQueueSend(inbox,&packet,0)!=pdTRUE)packetDropped=true;
}
bool send(const uint8_t* p,size_t n){
  return client&&client->isConnected()&&writer&&writer->writeValue(p,n,true);
}
bool save(const Packet &p){
  File r=LittleFS.open(SPOOL,"r");
  size_t existing=r?r.size():0;
  if(r)r.close();
  size_t needed=p.length*2+145;
  if(existing+needed>=MAX_SPOOL||LittleFS.totalBytes()-LittleFS.usedBytes()<needed+4096){
    Serial.println("FLASH FULL: refusing history ACK. Old records retained.");
    return false;
  }
  File f=LittleFS.open(SPOOL,"a");
  if(!f)return false;
  String line="{\"device\":\""+ringID+"\",\"channel\":"+String((unsigned)channel)
      +",\"seen\":"+String((unsigned long)time(nullptr))
      +",\"raw\":\""+hexdump(p.bytes,p.length)+"\"}\n";
  bool good=f.print(line)==line.length();
  f.flush();f.close();
  return good;
}
void receive(){
  Packet p{};
  while(xQueueReceive(inbox,&p,0)==pdTRUE){
    uint8_t op=p.bytes[0];
    if((op==0x47||op==0x4c||op==0x82||op==0x10||op==0x87)
       &&!ring::validFrame(p.bytes,p.length)){
      Serial.printf("Corrupt frame %02X; refusing ACK\n",op);failed=true;continue;
    }
    if(op==0x81&&p.length>=3&&p.bytes[1]==0x00){
      uint8_t reply[6];ring::authResponse(ringMAC,p.bytes[2],reply);
      authReplied=send(reply,sizeof(reply));
      if(!authReplied)failed=true;
      continue;
    }
    if(op==0x11){
      const uint8_t ack[]={0x91,0x00,0x00};
      if(!send(ack,sizeof(ack)))failed=true;
      continue;
    }
    // OSA 0x48 flood is not captured here; requires dedicated high-volume transport.
    if(op==0x48)continue;
    // Only archive raw history, cursor reports, status and sync-ACK evidence.
    if(op==0x47||op==0x4c||op==0x50||op==0x10||op==0x87||op==0x82){
      if(!save(p)){failed=true;continue;}
    }
    if(op==0x82&&p.length>=2&&p.bytes[1]==0xff)sawEmpty=true;
    if(op==0x47||op==0x4c){
      ++pages;lastPage=millis();
      const uint8_t ack[]={uint8_t(op==0x47?0xc7:0xcc),0,0};
      if(!send(ack,sizeof(ack)))failed=true;
      else Serial.printf("Saved + ACKed %02X page %lu\n",op,(unsigned long)pages);
    }
    if(op==0x50)sawEnd=true; // 0x50 deliberately has no XOR
  }
  if(packetDropped)failed=true; // never call a lossy stream complete
}
bool authenticate(){
  authReplied=false;
  if(!send(STATUS,sizeof(STATUS)))return false;
  uint32_t started=millis();
  while(millis()-started<10000){
    receive();
    if(failed||!client->isConnected())return false;
    if(authReplied){delay(300);return true;}
    delay(20);
  }
  Serial.println("No SM3 challenge");return false;
}
bool drain(uint8_t ch){
  channel=ch;pages=0;sawEnd=sawEmpty=false;lastPage=millis();
  if(!authenticate())return false;
  uint8_t cmd[9];ring::syncOpen((uint64_t)time(nullptr),ch,cmd);
  if(!send(cmd,sizeof(cmd)))return false;
  delay(300);receive();
  if(failed||!send(FETCH,sizeof(FETCH)))return false;
  Serial.printf("Opened history channel %02X\n",ch);
  uint32_t began=millis(),lastNudge=0;int nudges=0;
  while(millis()-began<200000UL){
    receive();
    if(failed||!client->isConnected())return false;
    if(sawEnd){Serial.printf("History %02X complete (%lu pages)\n",ch,(unsigned long)pages);return true;}
    if(sawEmpty&&!pages&&millis()-lastPage>4000)return true;
    if(!pages&&millis()-began>12000)return false;
    if(pages&&millis()-lastPage>5000){
      if(nudges<2&&(!lastNudge||millis()-lastNudge>5000)){
        if(!send(FETCH,sizeof(FETCH)))return false;
        lastNudge=millis();++nudges;
      }
      if(nudges>=2&&millis()-lastPage>15000)return false;
    }
    delay(15);
  }
  Serial.println("Partial history retained for retry");return false;
}
bool connectAndSync(){
  NimBLEScan *scan=NimBLEDevice::getScan();
  scan->setActiveScan(true);scan->setInterval(140);scan->setWindow(70);
  NimBLEScanResults advertisements=scan->getResults(6000);
  const NimBLEAdvertisedDevice* target=nullptr;
  for(int i=0;i<advertisements.getCount();++i){
    auto* d=advertisements.getDevice(i);
    Serial.printf("Nearby BLE: %s [%s]\n",d->getName().c_str(),d->getAddress().toString().c_str());
    if(d->getName()==std::string(RING_NAME)){target=d;break;}
  }
  if(!target){scan->clearResults();return false;}
  client=NimBLEDevice::createClient();
  bool success=false;
  do{
    if(!client||!client->connect(target)){Serial.println("BLE connect failed");break;}
    if(!client->secureConnection()){Serial.println("BLE bond failed");break;}
    auto* dis=client->getService(NimBLEUUID((uint16_t)0x180a));
    auto* sys=dis?dis->getCharacteristic(NimBLEUUID((uint16_t)0x2a23)):nullptr;
    if(!sys){Serial.println("System ID missing");break;}
    auto sid=sys->readValue();
    std::string raw(reinterpret_cast<const char*>(sid.data()),sid.size());
    if(!systemIDMac(raw,ringMAC)){Serial.println("Invalid System ID");break;}
    ringID=macText(ringMAC);
    if(strlen(RING_MAC)>0&&ringID!=String(RING_MAC)){
      Serial.println("Configured Ring MAC mismatch; refusing connection");break;
    }
    auto* svc=client->getService(ring::SERVICE_UUID);
    if(!svc){Serial.println("RingConn service not found");break;}
    writer=svc->getCharacteristic(ring::WRITE_UUID);
    auto* receiver=svc->getCharacteristic(ring::NOTIFY_UUID);
    if(!writer||!receiver||!receiver->canNotify()||!receiver->subscribe(true,notify)){
      Serial.println("Notify/write characteristic unavailable");break;
    }
    Serial.println("BLE notifications subscribed; starting authenticated drain");
    bool night=drain(0x00);
    bool day=!failed&&client->isConnected()?drain(0x03):false;
    success=night&&day&&!failed;
    send(STOP,sizeof(STOP));receive();
  }while(false);
  if(client){if(client->isConnected())client->disconnect();NimBLEDevice::deleteClient(client);}
  client=nullptr;writer=nullptr;scan->clearResults();
  return success;
}
bool wifi(){
  if(WiFi.status()==WL_CONNECTED)return true;
  WiFi.mode(WIFI_STA);WiFi.begin(WIFI_SSID,WIFI_PASSWORD);
  uint32_t t=millis();
  while(WiFi.status()!=WL_CONNECTED&&millis()-t<12000)delay(250);
  return WiFi.status()==WL_CONNECTED;
}
bool clockFromCollector(){
  HTTPClient http;
  if(!http.begin(String(COLLECTOR_URL)+"/time"))return false;
  http.setTimeout(7000);
  int status=http.GET();
  if(status!=200){http.end();return false;}
  time_t current=atoll(http.getString().c_str());http.end();
  if(current<1760000000LL)return false;
  struct timeval value{};value.tv_sec=current;settimeofday(&value,nullptr);
  return true;
}
bool upload(){
  File f=LittleFS.open(SPOOL,"r");
  if(!f)return true;
  if(!f.size()){f.close();LittleFS.remove(SPOOL);return true;}
  HTTPClient http;
  if(!http.begin(String(COLLECTOR_URL)+"/ingest")){f.close();return false;}
  http.setTimeout(60000);
  http.addHeader("X-Ring-Token",COLLECTOR_TOKEN);
  http.addHeader("Content-Type","application/x-ndjson");
  int code=http.sendRequest("POST",&f,f.size());
  http.end();f.close();
  if(code==200){LittleFS.remove(SPOOL);Serial.println("Collector committed spool");return true;}
  Serial.printf("Collector upload failed: HTTP %d; flash retained\n",code);return false;
}
// The collector only records a successful sync after confirming persisted
// termination evidence from BOTH history channels, not merely a successful upload.
bool confirmComplete(){
  if(!wifi())return false;
  HTTPClient http;
  if(!http.begin(String(COLLECTOR_URL)+"/complete"))return false;
  http.setTimeout(12000);
  http.addHeader("X-Ring-Token",COLLECTOR_TOKEN);
  http.addHeader("Content-Type","application/json");
  String payload="{\"device\":\""+ringID+"\",\"channels\":[0,3]}";
  int code=http.POST(payload);
  http.end();
  if(code!=200)Serial.printf("Completion not confirmed: HTTP %d\n",code);
  return code==200;
}
bool awakeWindow(){
  time_t now=time(nullptr);tm local{};localtime_r(&now,&local);
  return local.tm_hour>=SYNC_START_HOUR&&local.tm_hour<SYNC_END_HOUR;
}
} // namespace

void setup(){
  Serial.begin(115200);delay(250);
  Preferences pref;pref.begin("ringbridge",false);
  bool previouslyFormatted=pref.getBool("fs_ok",false);
  if(!LittleFS.begin(!previouslyFormatted)){
    Serial.println("FATAL: spool mount failed; will not format existing history");
    while(true)delay(1000);
  }
  if(!previouslyFormatted)pref.putBool("fs_ok",true);
  lastSuccess=(time_t)pref.getULong64("lastsync",0);
  pref.end();
  inbox=xQueueCreate(32,sizeof(Packet));
  if(!inbox){Serial.println("FATAL: BLE queue alloc");while(true)delay(1000);}
  NimBLEDevice::init("RingConn Gen2 Local Bridge");
  NimBLEDevice::setSecurityAuth(true,false,true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setMTU(517);
  setenv("TZ",LOCAL_TIMEZONE,1);tzset();
  Serial.println("RingConn Gen2 bridge ready; serial lists nearby BLE names");
}
void loop(){
  receive();
  if((int32_t)(millis()-nextAttempt)<0){delay(1000);return;}
  nextAttempt=millis()+RETRY_MS;
  if(!wifi()||!clockFromCollector()){Serial.println("Collector offline/time unavailable");return;}
  if(!upload())return; // never accumulate unbounded ACKed records
  time_t now=time(nullptr);
  if(!awakeWindow()||(lastSuccess&&now-lastSuccess<(time_t)SYNC_INTERVAL_SECONDS))return;
  failed=false;packetDropped=false;
  bool complete=connectAndSync();
  bool committed=upload();
  bool confirmed=complete&&committed&&confirmComplete();
  if(confirmed){
    lastSuccess=now;
    Preferences p;p.begin("ringbridge",false);p.putULong64("lastsync",(uint64_t)lastSuccess);p.end();
    nextAttempt=millis()+SYNC_INTERVAL_SECONDS*1000UL;
    Serial.println("Gen2 sleep + daytime channels synchronized");
  }else Serial.println("Partial/failed drain: queued flash pages retained; retry later");
}
