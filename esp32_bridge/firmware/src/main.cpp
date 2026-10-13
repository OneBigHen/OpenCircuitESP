#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include <sys/time.h>
#include <time.h>
#include <esp_partition.h>
#include <unistd.h>
#include <stdarg.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include "secrets.h"
#include "ring_protocol.h"
#include "spool_recovery.h"

// RingConn Gen 2 BLE central and local flash spool. Protocol source:
// OpenCircuit/docs/PROTOCOL.md, RingAuth.swift, RingSession.swift.
// Never ACK a history page until its bytes are durably written to flash.
// NOT YET HARDWARE-VALIDATED. Preserve the official app until an A/B sync works.
namespace {
// Diagnostics: every log line goes to USB serial AND a RAM buffer that is POSTed
// to the collector (/diag), so the bridge can be debugged over Wi-Fi alone.
const char *FW_VERSION="diag-8b";
char dbuf[4096];size_t dlen=0;
void dappend(const char*line){
  size_t n=strlen(line);
  if(n>200)n=200;
  if(dlen+n+1>=sizeof(dbuf)){size_t keep=sizeof(dbuf)/2;memmove(dbuf,dbuf+dlen-keep,keep);dlen=keep;}
  memcpy(dbuf+dlen,line,n);dlen+=n;dbuf[dlen++]='\n';dbuf[dlen]=0;
}
void dlog(const char*line){Serial.println(line);dappend(line);}
void dlogf(const char*fmt,...){
  char tmp[220];va_list ap;va_start(ap,fmt);vsnprintf(tmp,sizeof(tmp),fmt,ap);va_end(ap);
  size_t n=strlen(tmp);while(n&&(tmp[n-1]=='\n'||tmp[n-1]=='\r'))tmp[--n]=0;
  dlog(tmp);
}
// Active collector base URL; flips to COLLECTOR_URL_FALLBACK (if defined) when the primary stops answering.
String collectorUrl=COLLECTOR_URL;
constexpr uint32_t MAINTENANCE_RESTART_MS=7UL*24UL*3600UL*1000UL; // weekly, only while idle
constexpr uint32_t WATCHDOG_MS=600UL*1000UL; // longest legitimate blocking step is a ~420 s two-channel drain
const char *SPOOL="/pending.ndjson";
const char *SPOOL_PATH="/littlefs/pending.ndjson";
constexpr size_t MAX_SPOOL=900*1024;
const uint8_t STATUS[]={0x01,0x00,0x00};
const uint8_t FETCH[]={0x07,0x00,0x00};
const uint8_t STOP[]={0xd0,0x00,0x00};
constexpr uint32_t RETRY_MS=20UL*1000UL;
// Between full history syncs the bridge HOLDS one authenticated BLE link open and asks the
// ring for its status descriptor over it every HOLD_ASK_MS (one 3-byte write; far cheaper for
// the ring's battery than reconnecting). Charging-case events reach the collector in seconds.
// While the link is held the phone app cannot connect to the ring.
constexpr uint32_t HOLD_ASK_MS=15UL*1000UL;
constexpr uint32_t REACQUIRE_MS=10UL*1000UL; // retry cadence when the ring is out of reach
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
bool sawEnd=false,sawEmpty=false,authReplied=false,gotStatus=false;
bool ringSeenLast=true,holding=false;
uint32_t lastSummary=0;
// The ring's BLE address, learned from the first advert that matched and kept in NVS.
// A worn ring at range rarely delivers the scan response that carries its NAME, so
// matching by name alone missed it for hours. With the address known we connect
// directly: the radio listens 100% of the time for ANY advert from that address.
std::string ringAddr;uint8_t ringAddrType=0;
uint32_t lastAsk=0;
time_t lastSuccess=0;
time_t attemptStarted=0;

bool spoolPartitionBlank(){
  auto* partition=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                          ESP_PARTITION_SUBTYPE_DATA_SPIFFS,"spiffs");
  if(!partition)return false;
  uint8_t buffer[512];
  for(size_t offset=0;offset<partition->size;offset+=sizeof(buffer)){
    size_t n=partition->size-offset;
    if(n>sizeof(buffer))n=sizeof(buffer);
    if(esp_partition_read(partition,offset,buffer,n)!=ESP_OK)return false;
    for(size_t i=0;i<n;++i)if(buffer[i]!=0xff)return false;
  }
  return true;
}

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
  // Dense 0x48 OSA bursts can flood thousands of frames after a completed
  // history channel. We do not decode them yet: discard BEFORE queueing or
  // they can saturate the BLE queue and turn a good history sync into failure.
  if(len&&p&&p[0]==0x48)return;
  if(!inbox||!p||!len||len>512){packetDropped=true;return;}
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
    dlog("FLASH FULL: refusing history ACK. Old records retained.");
    return false;
  }
  FILE* f=fopen(SPOOL_PATH,"ab");
  if(!f)return false;
  String line="{\"device\":\""+ringID+"\",\"channel\":"+String((unsigned)channel)
      +",\"seen\":"+String((unsigned long)time(nullptr))
      +",\"raw\":\""+hexdump(p.bytes,p.length)+"\"}\n";
  bool good=fwrite(line.c_str(),1,line.length(),f)==line.length();
  if(fflush(f)!=0)good=false;
  if(fsync(fileno(f))!=0)good=false;
  if(fclose(f)!=0)good=false;
  return good;
}
void receive(){
  if(packetDropped)failed=true;
  if(failed)return;
  Packet p{};
  while(!failed&&!packetDropped&&xQueueReceive(inbox,&p,0)==pdTRUE){
    uint8_t op=p.bytes[0];
    if((op==0x47||op==0x4c||op==0x50||op==0x82||op==0x10||op==0x87)
       &&!ring::validFrame(p.bytes,p.length)){
      dlogf("Corrupt frame %02X; refusing ACK\n",op);failed=true;continue;
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
    if(op==0x10||op==0x87)gotStatus=true;
    // OSA 0x48 flood is not captured here; requires dedicated high-volume transport.
    if(op==0x48)continue;
    // Only archive raw history, cursor reports, status and sync-ACK evidence.
    if(op==0x47||op==0x4c||op==0x50||op==0x10||op==0x87||op==0x82){
      if(!save(p)){failed=true;break;} // no later ACK behind a torn record
    }
    if(op==0x82&&p.length>=2&&p.bytes[1]==0xff)sawEmpty=true;
    if(op==0x47||op==0x4c){
      ++pages;lastPage=millis();
      const uint8_t ack[]={uint8_t(op==0x47?0xc7:0xcc),0,0};
      if(!send(ack,sizeof(ack)))failed=true;
      else dlogf("Saved + ACKed %02X page %lu\n",op,(unsigned long)pages);
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
  dlog("No SM3 challenge");return false;
}
bool drain(uint8_t ch){
  channel=ch;pages=0;sawEnd=sawEmpty=false;lastPage=millis();
  if(!authenticate())return false;
  uint8_t cmd[9];ring::syncOpen((uint64_t)time(nullptr),ch,cmd);
  if(!send(cmd,sizeof(cmd)))return false;
  delay(300);receive();
  if(failed||!send(FETCH,sizeof(FETCH)))return false;
  dlogf("Opened history channel %02X\n",ch);
  uint32_t began=millis(),lastNudge=0;int nudges=0;
  while(millis()-began<200000UL){
    receive();
    if(failed||!client->isConnected())return false;
    if(sawEnd){dlogf("History %02X complete (%lu pages)\n",ch,(unsigned long)pages);return true;}
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
  dlog("Partial history retained for retry");return false;
}
// ---- Always-on listening -------------------------------------------------------------
// While no link is held the radio scans nonstop (window == interval, never ends). Every
// advert is checked in the BLE host callback; the moment the ring is heard the main loop
// stops the scan and connects while the ring is still in its advertising burst.
// Matching is by address or service as well as name: a worn ring at range rarely delivers
// the scan response that carries its name.
portMUX_TYPE heardMux=portMUX_INITIALIZER_UNLOCKED;
volatile bool ringHeard=false;
char heardAddr[18]={};uint8_t heardType=0;volatile int heardRssi=-127;volatile bool heardConnectable=false;
volatile uint32_t advCount=0,advConnectable=0;volatile int bestRssi5=-127;volatile uint8_t lastAdvType=255;
volatile uint32_t allAdv=0;
bool isRingAdvert(const NimBLEAdvertisedDevice* d){
  std::string a=d->getAddress().toString();
  if(!ringAddr.empty()&&a==ringAddr)return true;
  if(strlen(RING_MAC)&&strcasecmp(a.c_str(),RING_MAC)==0)return true;
  const std::string &n=d->getName();
  if(!n.empty()&&(n==std::string(RING_NAME)||n.rfind("RingConn Gen2",0)==0))return true;
  return d->isAdvertisingService(NimBLEUUID(ring::SERVICE_UUID));
}
class RingListener:public NimBLEScanCallbacks{
  void onDiscovered(const NimBLEAdvertisedDevice* d) override{
    ++allAdv;
    if(!isRingAdvert(d))return;
    int r=d->getRSSI();bool c=d->isConnectable();
    portENTER_CRITICAL(&heardMux);
    ++advCount;if(c)++advConnectable;if(r>bestRssi5)bestRssi5=r;lastAdvType=d->getAdvType();
    strncpy(heardAddr,d->getAddress().toString().c_str(),sizeof(heardAddr)-1);
    heardType=d->getAddressType();heardRssi=r;heardConnectable=c;
    if(c)ringHeard=true;
    portEXIT_CRITICAL(&heardMux);
  }
} listener;
void listen(){
  NimBLEScan *scan=NimBLEDevice::getScan();
  if(scan->isScanning())return;
  scan->setScanCallbacks(&listener,true); // duplicates on: we want EVERY ring advert
  scan->setMaxResults(0);                 // don't store results; the callback copies what it needs
  // Passive: the remembered address is enough, and with no scan requests every advert reaches onDiscovered.
  scan->setActiveScan(ringAddr.empty()&&!strlen(RING_MAC));scan->setInterval(100);scan->setWindow(100);
  scan->start(0,false,true);              // 0 = scan forever
}
void stopListening(){
  NimBLEScan *scan=NimBLEDevice::getScan();
  if(scan->isScanning())scan->stop();
  scan->clearResults();
}
void rememberHeard(){
  std::string a;uint8_t t;
  portENTER_CRITICAL(&heardMux);a=heardAddr;t=heardType;portEXIT_CRITICAL(&heardMux);
  if(a.empty()||(a==ringAddr&&t==ringAddrType))return;
  ringAddr=a;ringAddrType=t;
  Preferences p;p.begin("ringbridge",false);p.putString("addr",a.c_str());p.putUChar("atype",t);p.end();
  dlogf("Learned ring address %s (type %u)\n",a.c_str(),(unsigned)t);
}
// ---- Always-armed connection --------------------------------------------------------
// A disconnected RingConn saves battery by advertising only about once every ~100 s, and
// a link request has to answer within ~1 ms of an advert. So instead of scanning and then
// connecting (too late), the bridge keeps an asynchronous connect to the ring's address
// armed at all times: the controller listens 100% of the time and answers the very first
// advert. Wi-Fi housekeeping carries on meanwhile. Once linked, the link is held.
volatile bool connEvent=false,connOk=false;volatile int connReason=0;
bool armed=false;uint32_t armedCount=0,linkedCount=0,armedAt=0,armFail=0,timeouts=0;int lastArmErr=0;
class RingClientEvents:public NimBLEClientCallbacks{
  void onConnect(NimBLEClient*) override{connOk=true;connEvent=true;}
  void onConnectFail(NimBLEClient*,int reason) override{connOk=false;connReason=reason;connEvent=true;}
} clientEvents;
void armConnect(){
  if(armed||ringAddr.empty())return;
  if(!client){
    client=NimBLEDevice::createClient();
    if(!client)return;
    client->setClientCallbacks(&clientEvents,false);
    // 15-30 ms interval; 20 s supervision timeout so a hand or body briefly shadowing the ring
    // does not drop the held link; initiator scan interval == window (100% duty).
    client->setConnectionParams(12,24,0,2000,16,16);
    client->setConnectTimeout(60000);
  }
  connEvent=false;
  if(client->connect(NimBLEAddress(ringAddr,ringAddrType),true,true,true)){armed=true;armedAt=millis();++armedCount;}
  else{++armFail;lastArmErr=client->getLastError();}
}
void ringSummary(){
  if(millis()-lastSummary<(lastSummary?5UL*60UL*1000UL:90UL*1000UL))return;
  lastSummary=millis();
  if(ringAddr.empty()){
    uint32_t n=advCount,all=allAdv;advCount=0;allAdv=0;
    dlogf("Ring (5 min): address not learned yet; %lu ring adverts, %lu other adverts\n",(unsigned long)n,(unsigned long)all);
  }else dlogf("Ring (5 min): listening continuously for %s, connected %lu time(s); %lu listen windows, %lu ran out, %lu could not start (err %d)\n",ringAddr.c_str(),(unsigned long)linkedCount,(unsigned long)armedCount,(unsigned long)timeouts,(unsigned long)armFail,lastArmErr);
  armedCount=linkedCount=armFail=timeouts=0;
}
bool connectAndSync(bool statusOnly=false,bool keepOpen=false){
  attemptStarted=time(nullptr);
  NimBLEScan *scan=NimBLEDevice::getScan();
  bool linked=client&&client->isConnected();
  if(linked){++linkedCount;dlogf("Ring connected, signal %d dBm\n",client->getRssi());}
  ringSeenLast=linked;
  bool success=false;
  do{
    if(!client||!linked){dlog("BLE connect failed");break;}
    if(!client->secureConnection()){dlog("BLE bond failed");break;}
    auto* dis=client->getService(NimBLEUUID((uint16_t)0x180a));
    auto* sys=dis?dis->getCharacteristic(NimBLEUUID((uint16_t)0x2a23)):nullptr;
    if(!sys){dlog("System ID missing");break;}
    auto sid=sys->readValue();
    std::string raw(reinterpret_cast<const char*>(sid.data()),sid.size());
    if(!systemIDMac(raw,ringMAC)){dlog("Invalid System ID");break;}
    ringID=macText(ringMAC);
    if(strlen(RING_MAC)>0&&ringID!=String(RING_MAC)){
      dlog("Configured Ring MAC mismatch; refusing connection");break;
    }
    auto* svc=client->getService(ring::SERVICE_UUID);
    if(!svc){dlog("RingConn service not found");break;}
    writer=svc->getCharacteristic(ring::WRITE_UUID);
    auto* receiver=svc->getCharacteristic(ring::NOTIFY_UUID);
    if(!writer||!receiver||!receiver->canNotify()||!receiver->subscribe(true,notify)){
      dlog("Notify/write characteristic unavailable");break;
    }
    if(statusOnly){
      gotStatus=false;
      if(!authenticate())break;
      if(!send(STOP,sizeof(STOP)))break; // d0 00 00 makes the ring answer with a status descriptor
      uint32_t asked=millis();
      while(!gotStatus&&!failed&&client->isConnected()&&millis()-asked<6000){receive();delay(20);}
      receive();
      success=gotStatus&&!failed;
      if(!success)dlog("Status poll: no descriptor");
      break;
    }
    dlog("BLE notifications subscribed; starting authenticated drain");
    bool night=drain(0x00);
    bool day=!failed&&client->isConnected()?drain(0x03):false;
    success=night&&day&&!failed;
    send(STOP,sizeof(STOP)); // STOP may return status 0x50; do not archive it
  }while(false);
  if(statusOnly&&keepOpen&&success)return true; // link stays open for holdTick()
  if(client){if(client->isConnected())client->disconnect();NimBLEDevice::deleteClient(client);}
  client=nullptr;writer=nullptr;scan->clearResults();
  xQueueReset(inbox); // late notifications belong to the closed connection
  return success;
}
void dropLink(){
  if(client){if(client->isConnected())client->disconnect();NimBLEDevice::deleteClient(client);}
  client=nullptr;writer=nullptr;holding=false;
  NimBLEDevice::getScan()->clearResults();
  xQueueReset(inbox);
}
bool wifi(){
  if(WiFi.status()==WL_CONNECTED)return true;
  WiFi.mode(WIFI_STA);WiFi.begin(WIFI_SSID,WIFI_PASSWORD);
  uint32_t t=millis();
  while(WiFi.status()!=WL_CONNECTED&&millis()-t<12000)delay(250);
  return WiFi.status()==WL_CONNECTED;
}
bool fetchTime(const String &base){
  HTTPClient http;
  if(!http.begin(base+"/time"))return false;
  http.setTimeout(7000);
  int status=http.GET();
  if(status!=200){http.end();return false;}
  time_t current=atoll(http.getString().c_str());http.end();
  if(current<1760000000LL)return false;
  struct timeval value{};value.tv_sec=current;settimeofday(&value,nullptr);
  return true;
}
bool clockFromCollector(){
  if(fetchTime(collectorUrl))return true;
#ifdef COLLECTOR_URL_FALLBACK
  String other=collectorUrl==String(COLLECTOR_URL)?String(COLLECTOR_URL_FALLBACK):String(COLLECTOR_URL);
  if(fetchTime(other)){collectorUrl=other;dlogf("Collector switched to %s\n",other.c_str());return true;}
#endif
  return false;
}
bool upload(){
  if(!ring::recoverSpool(SPOOL_PATH)){
    dlog("ALERT: spool recovery failed; history retained");return false;
  }
  File f=LittleFS.open(SPOOL,"r");
  if(!f)return true;
  if(!f.size()){f.close();LittleFS.remove(SPOOL);return true;}
  HTTPClient http;
  if(!http.begin(collectorUrl+"/ingest")){f.close();return false;}
  http.setTimeout(60000);
  http.addHeader("X-Ring-Token",COLLECTOR_TOKEN);
  http.addHeader("Content-Type","application/x-ndjson");
  int code=http.sendRequest("POST",&f,f.size());
  String receipt=code==200?http.getString():String();
  http.end();f.close();
  // An unrelated HTTP server returning 200 must never erase the flash spool.
  bool acknowledged=code==200 &&
    (receipt.indexOf("\"committed\": true")>=0 ||
     receipt.indexOf("\"committed\":true")>=0);
  if(acknowledged){LittleFS.remove(SPOOL);dlog("Collector committed spool");return true;}
  dlogf("Collector upload failed: HTTP %d; flash retained\n",code);return false;
}
// The collector only records a successful sync after confirming persisted
// termination evidence from BOTH history channels, not merely a successful upload.
bool confirmComplete(){
  if(!wifi())return false;
  HTTPClient http;
  if(!http.begin(collectorUrl+"/complete"))return false;
  http.setTimeout(12000);
  http.addHeader("X-Ring-Token",COLLECTOR_TOKEN);
  http.addHeader("Content-Type","application/json");
  String payload="{\"device\":\""+ringID+"\",\"channels\":[0,3],\"started\":"
      +String((unsigned long)attemptStarted)+"}";
  int code=http.POST(payload);
  String receipt=code==200?http.getString():String();
  http.end();
  if(code!=200)dlogf("Completion not confirmed: HTTP %d\n",code);
  return code==200&&(receipt.indexOf("\"confirmed\": true")>=0||
                    receipt.indexOf("\"confirmed\":true")>=0);
}
void holdTick(){
  if(failed||packetDropped||!client||!client->isConnected()){
    dlog("Ring link dropped");dropLink();failed=false;packetDropped=false;
    nextAttempt=millis()+2000;return;
  }
  time_t now=time(nullptr);
  if(lastSuccess&&now-lastSuccess>=(time_t)SYNC_INTERVAL_SECONDS){
    dlog("Full sync due; releasing held link");dropLink();nextAttempt=0;return;
  }
  if(gotStatus){gotStatus=false;if(wifi()&&!upload())clockFromCollector();}
  if(millis()-lastAsk>=HOLD_ASK_MS){lastAsk=millis();if(!send(STOP,sizeof(STOP)))failed=true;}
  delay(50);
}
void diagPost(){
  if(WiFi.status()!=WL_CONNECTED||!dlen)return;
  HTTPClient http;
  if(!http.begin(collectorUrl+"/diag"))return;
  http.setTimeout(6000);
  http.addHeader("X-Ring-Token",COLLECTOR_TOKEN);
  http.addHeader("Content-Type","text/plain");
  char head[200];
  snprintf(head,sizeof(head),"fw=%s up=%lus heap=%u rssi=%d reset=%d\n",FW_VERSION,
           (unsigned long)(millis()/1000),(unsigned)ESP.getFreeHeap(),(int)WiFi.RSSI(),(int)esp_reset_reason());
  String body=String(head)+dbuf;
  int code=http.POST(body);http.end();
  if(code==200){dlen=0;dbuf[0]=0;}
}
bool awakeWindow(){
  time_t now=time(nullptr);tm local{};localtime_r(&now,&local);
  return local.tm_hour>=SYNC_START_HOUR&&local.tm_hour<SYNC_END_HOUR;
}
} // namespace

void setup(){
  Serial.begin(115200);delay(250);
  Preferences pref;pref.begin("ringbridge",false);
  // NVS can be cleared independently of the spool. Never use an NVS marker
  // as permission to format. First mount; only initialize a fully erased area.
  if(!LittleFS.begin(false)){
    if(!spoolPartitionBlank()||!LittleFS.begin(true)){
      dlog("FATAL: spool mount failed; will not format existing history");
      while(true)delay(1000);
    }
  }
  lastSuccess=(time_t)pref.getULong64("lastsync",0);
  pref.end();
  inbox=xQueueCreate(32,sizeof(Packet));
  if(!inbox){dlog("FATAL: BLE queue alloc");while(true)delay(1000);}
  NimBLEDevice::init("RingConn Gen2 Local Bridge");
  NimBLEDevice::setSecurityAuth(true,false,true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setPower(9); // max TX power: a ring's tiny antenna needs every dB on the link
  {Preferences p;p.begin("ringbridge",true);ringAddr=p.getString("addr","").c_str();ringAddrType=p.getUChar("atype",0);p.end();}
  setenv("TZ",LOCAL_TIMEZONE,1);tzset();
  esp_task_wdt_config_t wdt={};wdt.timeout_ms=WATCHDOG_MS;wdt.idle_core_mask=0;wdt.trigger_panic=true;
  if(esp_task_wdt_reconfigure(&wdt)!=ESP_OK)esp_task_wdt_init(&wdt);
  esp_task_wdt_add(nullptr);
  dlog("RingConn Gen2 bridge ready; serial lists nearby BLE names");
}
uint32_t nextHousekeeping=0;
void housekeeping(){
  if((int32_t)(millis()-nextHousekeeping)<0)return;
  nextHousekeeping=millis()+RETRY_MS;
  if(!wifi()||!clockFromCollector())dlog("Collector offline/time unavailable");
  else upload();
}
void cycle(){
  receive();
  if(holding){holdTick();return;}
  if(millis()>MAINTENANCE_RESTART_MS){dlog("Weekly maintenance restart");diagPost();delay(300);ESP.restart();}
  ringSummary();
  if(ringAddr.empty()){ // first run only: find the ring by name/service and remember its address
    listen();
    if(ringHeard){stopListening();rememberHeard();ringHeard=false;}
    housekeeping();delay(20);return;
  }
  armConnect();
  if(!connEvent){housekeeping();delay(20);return;}
  connEvent=false;armed=false;
  if(!connOk){
    if(connReason==BLE_HS_ETIMEOUT)++timeouts;else dlogf("Ring connect failed (reason %d)\n",connReason);
    delay(200);return; // re-armed on the next pass
  }
  if(time(nullptr)<1760000000LL){if(!wifi()||!clockFromCollector()){dlog("No clock yet; releasing ring");dropLink();return;}}
  if(!awakeWindow()){dropLink();return;}
  time_t now=time(nullptr);
  failed=false;packetDropped=false;
  if(lastSuccess&&now-lastSuccess<(time_t)SYNC_INTERVAL_SECONDS){
    if(connectAndSync(true,true)){holding=true;lastAsk=millis();dlog("Holding ring link; status every 15 s");if(wifi())upload();}
    return;
  }
  bool complete=connectAndSync();
  bool committed=wifi()&&upload();
  bool confirmed=complete&&committed&&confirmComplete();
  if(confirmed){
    lastSuccess=now;
    Preferences p;p.begin("ringbridge",false);p.putULong64("lastsync",(uint64_t)lastSuccess);p.end();
    dlog("Gen2 sleep + daytime channels synchronized");
  }else dlog("Partial/failed drain: queued flash pages retained; retry later");
}
void loop(){esp_task_wdt_reset();cycle();diagPost();}
