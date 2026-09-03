"""Untrapped Update Middleman 3.2.0 - TRUE BASELINE infrastructure."""
from __future__ import annotations
import base64, hashlib, json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote
from urllib.request import Request, urlopen
VERSION="3.2.0"; PROTOCOL=3; BASELINE="1.0.0"
UPSTREAM=os.environ.get("UNTRAPPED_UPSTREAM","https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/")
PORT=int(os.environ.get("PORT","8080")); MAX_BYTES=int(os.environ.get("MAX_ARTIFACT_BYTES",str(8*1024*1024)))
ARTIFACTS=["manifest.json","background.js","content.js","popup.html","popup.js","bootstrap.bundle.min.js","assets/untrapped.png","assets/untrapped.svg","VERSION.txt","ultra-mode/INSTALL-PACKET-FILTER.ps1","ultra-mode/INSTALL-ULTRA-NODE.ps1","ultra-mode/INSTALL-ULTRA-MODE.ps1","ultra-mode/config.json","ultra-mode/create-override.ps1","ultra-mode/generate-keys.ps1","ultra-mode/packet-filter.ps1","ultra-mode/self-repair.ps1","ultra-mode/status-untrapped.ps1","ultra-mode/test-untrapped.ps1","ultra-mode/ultra-mode.ps1","ultra-mode/verify-override.ps1"]
ALLOW=frozenset(ARTIFACTS); _cache={}; _lock=threading.Lock()
def sha256(b): return hashlib.sha256(b).hexdigest()
def fetch(path):
 r=Request(UPSTREAM+path+"?middleman="+str(time.time_ns()),headers={"User-Agent":"Untrapped-Middleman/3.2"})
 with urlopen(r,timeout=30) as x:b=x.read(MAX_BYTES+1)
 if len(b)>MAX_BYTES: raise ValueError("artifact exceeds size limit")
 return b
def normalize(raw,path):
 if path.endswith('.json'):
  json.loads(raw.decode('utf-8-sig','strict')); return raw
 try:text=raw.decode('utf-8-sig','strict')
 except UnicodeDecodeError: return raw
 if not text.lstrip().startswith('{'): return raw
 try:o=json.loads(text)
 except Exception:return raw
 lang=str(o.get('language',o.get('lang',o.get('target',o.get('type',''))))).lower() if isinstance(o,dict) else ''
 explicit=lang in {'powershell','powershell-script','powershellscript','ps1','pwsh'}
 if not isinstance(o,dict) or not explicit:return raw
 enc=str(o.get('encoding',o.get('content_encoding',''))).lower()
 for k in ('powershell','script','source','code','content','text','body'):
  if isinstance(o.get(k),str):
   v=o[k]
   if enc.replace('-','')=='base64':v=base64.b64decode(v,validate=True).decode('utf-8-sig')
   return (v.rstrip()+"\n").encode('utf-8')
 if isinstance(o.get('commands'),list) and all(isinstance(x,str) for x in o['commands']):return ('\n'.join(o['commands']).rstrip()+"\n").encode('utf-8')
 return raw
def artifact(path):
 with _lock:
  if path in _cache:return _cache[path]
 b=normalize(fetch(path),path)
 with _lock:_cache[path]=b
 return b
class Handler(BaseHTTPRequestHandler):
 server_version="UntrappedMiddleman/3.2"
 def send_json(self,c,o):
  b=json.dumps(o,indent=2).encode();self.send_response(c);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def do_GET(self):
  try:
   p=unquote(self.path.split('?',1)[0])
   if p=='/health':return self.send_json(200,{'ok':True,'service':'Untrapped Update Middleman','version':VERSION,'protocol':PROTOCOL,'baseline':BASELINE,'status_audit':'000-999 accounted for'})
   if p=='/v1/manifest':
    items=[]
    for n in ARTIFACTS:
     try:b=artifact(n);items.append({'path':n,'sha256':sha256(b),'bytes':len(b),'available':True})
     except Exception as e:items.append({'path':n,'available':False,'error':str(e)})
    return self.send_json(200,{'service':'Untrapped Update Middleman','version':VERSION,'protocol':PROTOCOL,'baseline':BASELINE,'artifacts':items,'status_audit':{'numeric_identifiers':1000,'range':'000-999','standard_http':'100-599','nonstandard_reserved_numeric':'000-099,600-999'}})
   pre='/v1/artifact/'
   if not p.startswith(pre):return self.send_json(404,{'error':'not_found'})
   n=p[len(pre):]
   if n not in ALLOW:return self.send_json(404,{'error':'artifact_not_allowlisted'})
   b=artifact(n);self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Cache-Control','no-store');self.send_header('X-Untrapped-SHA256',sha256(b));self.send_header('X-Untrapped-Baseline',BASELINE);self.send_header('X-Untrapped-Protocol',str(PROTOCOL));self.send_header('X-Untrapped-Version',VERSION);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
  except json.JSONDecodeError as e:self.send_json(422,{'error':'invalid_json','detail':str(e)})
  except Exception as e:self.send_json(502,{'error':'upstream_unavailable','detail':str(e)})
 def log_message(self,f,*a):print('[middleman] '+f%a,flush=True)
if __name__=='__main__':
 print('[middleman] Untrapped Update Middleman',VERSION,'starting on port',PORT,flush=True);print('[middleman] Baseline floor:',BASELINE,flush=True);print('[middleman] Status audit: 000-999 / 1000 numeric identifiers accounted for',flush=True);ThreadingHTTPServer(('0.0.0.0',PORT),Handler).serve_forever()
