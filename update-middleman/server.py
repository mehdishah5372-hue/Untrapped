"""Untrapped Update Middleman 3.2.0 - hardened TRUE BASELINE infrastructure."""
from __future__ import annotations
import base64, hashlib, json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import unquote
from urllib.request import Request, urlopen
VERSION="3.2.0"; PROTOCOL=3; BASELINE="1.0.0"
UPSTREAM=os.environ.get("UNTRAPPED_UPSTREAM","https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/").rstrip("/")+"/"
PORT=int(os.environ.get("PORT","8080")); MAX_BYTES=int(os.environ.get("MAX_ARTIFACT_BYTES",str(8*1024*1024))); FETCH_ATTEMPTS=5; FETCH_TIMEOUT=30; MAX_PATH=512
ARTIFACTS=["manifest.json","background.js","content.js","popup.html","popup.js","bootstrap.bundle.min.js","assets/untrapped.png","assets/untrapped.svg","VERSION.txt","ultra-mode/INSTALL-PACKET-FILTER.ps1","ultra-mode/INSTALL-ULTRA-NODE.ps1","ultra-mode/INSTALL-ULTRA-MODE.ps1","ultra-mode/config.json","ultra-mode/create-override.ps1","ultra-mode/generate-keys.ps1","ultra-mode/packet-filter.ps1","ultra-mode/self-repair.ps1","ultra-mode/status-untrapped.ps1","ultra-mode/test-untrapped.ps1","ultra-mode/ultra-mode.ps1","ultra-mode/verify-override.ps1"]
ALLOW=frozenset(ARTIFACTS); _cache={}; _lock=threading.RLock()
def sha256(b): return hashlib.sha256(b).hexdigest()
def _retry_delay(attempt,headers):
 v=headers.get("Retry-After") if headers else None
 if v:
  try:return min(max(int(v),1),30)
  except Exception:pass
 return min(2**(attempt-1),8)
def _read_limited(stream):
 chunks=[];total=0
 try:
  while True:
   remaining=MAX_BYTES-total
   if remaining<=0: raise ValueError("artifact exceeds size limit")
   chunk=stream.read(min(65536,remaining+1))
   if not chunk:break
   total+=len(chunk)
   if total>MAX_BYTES:raise ValueError("artifact exceeds size limit")
   chunks.append(chunk)
 finally:stream.close()
 return b"".join(chunks)
def fetch(path):
 if not isinstance(path,str) or len(path)>MAX_PATH or path.startswith('/') or '..' in path.split('/') or '\\' in path:raise ValueError("invalid upstream artifact path")
 last=None
 for attempt in range(1,FETCH_ATTEMPTS+1):
  try:
   req=Request(UPSTREAM+path+"?middleman="+str(time.time_ns()),headers={"User-Agent":"Untrapped-Middleman/3.2","Accept":"*/*","Cache-Control":"no-cache"})
   with urlopen(req,timeout=FETCH_TIMEOUT) as res:
    length=res.headers.get_content_length()
    if length is not None and length>MAX_BYTES:raise ValueError("artifact exceeds size limit")
    return _read_limited(res)
  except HTTPError as e:
   last=e;code=int(e.code)
   if code in (408,425,429) or 500<=code<=599:
    if attempt<FETCH_ATTEMPTS:
     delay=_retry_delay(attempt,e.headers);print(f"[middleman] retryable upstream HTTP {code} for {path}; retry {attempt+1}/{FETCH_ATTEMPTS} in {delay}s",flush=True);time.sleep(delay);continue
   raise ValueError(f"upstream HTTP {code} for canonical artifact {path}") from e
  except (URLError,TimeoutError,ConnectionError,OSError) as e:
   last=e
   if attempt<FETCH_ATTEMPTS:
    delay=min(2**(attempt-1),8);print(f"[middleman] upstream transport failure for {path}; retry {attempt+1}/{FETCH_ATTEMPTS} in {delay}s: {e}",flush=True);time.sleep(delay);continue
   break
  except Exception as e:
   last=e;break
 raise last if last else RuntimeError("upstream fetch failed")
def normalize(raw,path):
 if path.endswith('.json'):
  json.loads(raw.decode('utf-8-sig','strict'));return raw
 try:text=raw.decode('utf-8-sig','strict')
 except UnicodeDecodeError:return raw
 if not text.lstrip().startswith('{'):return raw
 try:o=json.loads(text)
 except Exception:return raw
 if not isinstance(o,dict):return raw
 lang=str(o.get('language',o.get('lang',o.get('target',o.get('type',''))))).lower()
 if lang not in {'powershell','powershell-script','powershellscript','ps1','pwsh'}:return raw
 enc=str(o.get('encoding',o.get('content_encoding',''))).lower().replace('-','')
 for k in ('powershell','script','source','code','content','text','body'):
  if isinstance(o.get(k),str):
   v=o[k]
   if enc=='base64':v=base64.b64decode(v,validate=True).decode('utf-8-sig')
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
 server_version="UntrappedMiddleman/3.2";protocol_version="HTTP/1.1"
 def send_json(self,code,obj,extra=None):
  b=json.dumps(obj,indent=2,ensure_ascii=False).encode('utf-8');self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Content-Length',str(len(b)))
  if extra:
   for k,v in extra.items():self.send_header(k,str(v))
  self.end_headers();self.wfile.write(b)
 def do_HEAD(self):
  p=unquote(self.path.split('?',1)[0])
  if p=='/health':self.send_response(200);self.send_header('Content-Length','0');self.send_header('Cache-Control','no-store');self.end_headers();return
  self.send_response(404);self.send_header('Content-Length','0');self.end_headers()
 def do_GET(self):
  try:
   raw_path=self.path.split('?',1)[0]
   if len(raw_path)>MAX_PATH+20:return self.send_json(414,{'error':'uri_too_long'})
   p=unquote(raw_path)
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
   b=artifact(n);self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('X-Untrapped-SHA256',sha256(b));self.send_header('X-Untrapped-Baseline',BASELINE);self.send_header('X-Untrapped-Protocol',str(PROTOCOL));self.send_header('X-Untrapped-Version',VERSION);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
  except ValueError as e:self.send_json(502,{'error':'upstream_artifact_invalid_or_unavailable','detail':str(e)}, {'X-Untrapped-Failure-Class':'upstream'})
  except json.JSONDecodeError as e:self.send_json(502,{'error':'invalid_upstream_json','detail':str(e)}, {'X-Untrapped-Failure-Class':'upstream-json'})
  except HTTPError as e:self.send_json(502,{'error':'upstream_http_error','detail':str(e)}, {'X-Untrapped-Upstream-Status':e.code,'X-Untrapped-Failure-Class':'upstream-http'})
  except Exception as e:self.send_json(502,{'error':'upstream_unavailable','detail':str(e)}, {'X-Untrapped-Failure-Class':'upstream'})
 def log_message(self,f,*a):print('[middleman] '+f%a,flush=True)
if __name__=='__main__':
 print('[middleman] Untrapped Update Middleman',VERSION,'starting on port',PORT,flush=True);print('[middleman] Baseline floor:',BASELINE,flush=True);print('[middleman] Status audit: 000-999 / 1000 numeric identifiers accounted for',flush=True);ThreadingHTTPServer(('0.0.0.0',PORT),Handler).serve_forever()
