"""Screenshot the live /ring-health/ring view. Needs HASS_TOKEN; writes /tmp/ha_ring_{desk,phone}.png."""
import os,time
from playwright.sync_api import sync_playwright
base='http://192.168.1.146:8123';tok=os.environ['HASS_TOKEN']
FIND='''()=>{const f=(r)=>{for(const e of r.querySelectorAll("*")){if(e.tagName=="RINGCONN-CARD")return true;if(e.shadowRoot&&f(e.shadowRoot))return true}return false};return f(document)}'''
with sync_playwright() as p:
    b=p.chromium.launch()
    for w,h,name in ((1280,1400,'desk'),(420,2400,'phone')):
        pg=b.new_page(viewport={'width':w,'height':h})
        pg.route('**/*.woff2',lambda r:r.abort());pg.route('**/*.woff',lambda r:r.abort())
        errs=[];pg.on('console',lambda m:errs.append(m.text) if m.type=='error' else None)
        pg.goto(base+'/auth/authorize?response_type=code')
        pg.evaluate('''([b,t])=>localStorage.setItem("hassTokens",JSON.stringify({access_token:t,token_type:"Bearer",expires_in:315360000,hassUrl:b,clientId:b+"/",expires:Date.now()+315360000000,refresh_token:""}))''',[base,tok])
        pg.goto(base+'/ring-health/ring');pg.wait_for_function(FIND,timeout=150000);time.sleep(5)
        pg.screenshot(path=f'/tmp/ha_ring_{name}.png',timeout=90000)
        print(name,'card rendered; ringconn console errors:',[e for e in errs if 'ringconn' in e.lower()])
    b.close()
