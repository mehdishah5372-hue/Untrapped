"""Untrapped Update Middleman 3.1.0 - TRUE BASELINE infrastructure.

Read/update broker for allow-listed Untrapped artifacts. Normalizes explicit
JSON source envelopes and returns exact SHA-256 metadata. Baseline enforcement
is client-side. PowerShell syntax validation is deliberately client-side.

3.1.0 removes the old bogus delimiter-count validator that caused false 422s.
NO 409 HERE: artifact reads do not reject scripts based on character counts.
"""
from __future__ import annotations
import base64, hashlib, json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote
from urllib.request import Request, urlopen

VERSION="3.1.0"; PROTOCOL=3; BASELINE="1.0.0"
UPSTREAM=os.environ.get("UNTRAPPED_UPSTREAM","https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/")
PORT=int(os.environ.get("PORT","8080")); CACHE_TTL=max(0,int(os.environ.get("CACHE_TTL","30"))); MAX_BYTES=int(os.environ.get("MAX_ARTIFACT_BYTES",str(8*1024*1024)))
ARTIFACTS=["manifest.json","background.js","content.js","popup.html","popup.js","bootstrap.bundle.min.js","assets/untrapped.png","assets/untrapped.svg","VERSION.txt","ultra-mode/INSTALL-PACKET-FILTER.ps1","ultra-mode/INSTALL-ULTRA-MODE.ps1","ultra-mode/config.json","ultra-mode/create-override.ps1","ultra-mode/generate-keys.ps1","ultra-mode/packet-filter.ps1","ultra-mode/self-repair.ps1","ultra-mode/status-untrapped.ps1","ultra-mode/test-untrapped.ps1","ultra-mode/ultra-mode.ps1","ultra-mode/verify-override.ps1"]
ALLOW=frozenset(ARTIFACTS); _cache={}; _lock=threading.Lock()
class TranslationError(ValueError): pass
def sha256(b): return hashlib.sha256(b).hexdigest()
def version_tuple(text):
    head="\n".join(x for x in text.splitlines() if x.strip()); head="\n".join(head.splitlines()[:12]); m=re.search(r"(?im)^(?:#|//)\s*[^\r\n]*?\bver(?:sion)?\s+([0-9]+\.[0-9]+\.[0-9]+)\b",head)
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,0,0)
def dotted(v): return ".".join(map(str,v))
def clean_text(s): return s.lstrip("\ufeff").replace("\r\n","\n").replace("\r","\n").strip()+"\n"
def ps_lint(s):
    e=[]
    if not s.strip(): e.append("PowerShell payload is empty")
    try: n=len(s.encode("utf-8"))
    except UnicodeEncodeError: e.append("PowerShell payload is not valid UTF-8"); n=0
    if n>MAX_BYTES: e.append("PowerShell payload exceeds size limit")
    if "\x00" in s: e.append("PowerShell payload contains NUL bytes")
    return e
def json_to_ps(v,ind=0):
    p=" "*ind
    if v is None:return "$null"
    if v is True:return "$true"
    if v is False:return "$false"
    if isinstance(v,(int,float)) and not isinstance(v,bool):return str(v).lower()
    if isinstance(v,str):return "'"+v.replace("'","''")+"'"
    if isinstance(v,list): return "@()" if not v else "@(\n"+",\n".join(" "*(ind+4)+json_to_ps(x,ind+4) for x in v)+"\n"+p+")"
    if isinstance(v,dict): return "@{}" if not v else "@{\n"+";\n".join(" "*(ind+4)+"'"+str(k).replace("'","''")+"' = "+json_to_ps(x,ind+4) for k,x in v.items())+"\n"+p+"}"
    raise TranslationError("unsupported JSON value")
def decode_payload(v,enc):
    if not isinstance(v,str): raise TranslationError("source payload must be a string")
    if enc.lower().replace("-","")=="base64":
        try:return base64.b64decode(v,validate=True).decode("utf-8-sig")
        except Exception as ex: raise TranslationError("invalid base64 source payload") from ex
    return v
def normalize(raw,path):
    if len(raw)>MAX_BYTES: raise TranslationError("artifact exceeds size limit")
    meta={"input_sha256":sha256(raw),"output_sha256":sha256(raw),"mode":"unchanged","translated":False,"reason":"already source/text"}
    if path.endswith(".json"):
        try: json.loads(raw.decode("utf-8-sig","strict"))
        except Exception as ex: raise TranslationError("invalid JSON configuration: "+str(ex)) from ex
        meta["reason"]="JSON configuration preserved byte-for-byte"; return raw,False,meta
    try:text=raw.decode("utf-8-sig","strict")
    except UnicodeDecodeError as ex: raise TranslationError("artifact is not valid UTF-8") from ex
    if not text.strip().startswith(("{","[",'"')): return raw,False,meta
    try: obj=json.loads(text.strip())
    except Exception: meta["reason"]="not a JSON source wrapper; preserved as source/text"; return raw,False,meta
    lang=str(obj.get("language",obj.get("lang",obj.get("target",obj.get("type",""))))).lower() if isinstance(obj,dict) else ""
    explicit=lang in {"powershell","powershell-script","powershellscript","ps1","pwsh"}; source=None; reason=""
    if isinstance(obj,str) and path.endswith(".ps1"): source=obj; reason="top-level JSON string targeted to .ps1"
    elif isinstance(obj,dict):
        enc=str(obj.get("encoding",obj.get("content_encoding","")))
        for k in ("powershell","script","source","code","content","text","body"):
            if k not in obj: continue
            v=obj[k]
            if isinstance(v,str): source=decode_payload(v,enc); reason="explicit source envelope: "+k; break
            if explicit and isinstance(v,(dict,list,int,float,bool)): source="# JSON-to-PowerShell data translation\n$data = "+json_to_ps(v); reason="explicit PowerShell data payload: "+k; break
            raise TranslationError("source key '"+k+"' must contain text")
        if source is None and explicit and any(k in obj for k in ("commands","statements")):
            v=obj.get("commands",obj.get("statements"))
            if not isinstance(v,list) or not all(isinstance(x,str) for x in v): raise TranslationError("commands/statements must be a list of strings")
            source="\n".join(x.strip("\r\n") for x in v); reason="explicit PowerShell command list"
        if source is None and explicit and "data" in obj: source="# JSON-to-PowerShell data translation\n$data = "+json_to_ps(obj["data"]); reason="explicit PowerShell data object"
    if source is None: meta["reason"]="ordinary JSON structure; no explicit source envelope"; return raw,False,meta
    source=clean_text(source); errors=ps_lint(source)
    if errors: raise TranslationError("; ".join(errors))
    out=source.encode("utf-8"); meta.update(output_sha256=sha256(out),mode="json-envelope-translation",translated=True,reason=reason); return out,True,meta
def fetch_upstream(path):
    r=Request(UPSTREAM+path+"?middleman="+str(time.time_ns()),headers={"User-Agent":"Untrapped-Middleman/3.1"})
    with urlopen(r,timeout=30) as resp:data=resp.read(MAX_BYTES+1)
    if len(data)>MAX_BYTES: raise TranslationError("upstream artifact exceeds size limit")
    return data
def artifact(path):
    now=time.time()
    with _lock:
        h=_cache.get(path)
        if h and now-h[0]<CACHE_TTL:return h[1]
    x=normalize(fetch_upstream(path),path)
    with _lock:_cache[path]=(now,x)
    return x
def manifest():
    a=[]
    for p in ARTIFACTS:
        d,t,m=artifact(p); txt=d.decode("utf-8","replace") if p.endswith(".ps1") else ""
        a.append({"path":p,"sha256":sha256(d),"bytes":len(d),"version":dotted(version_tuple(txt)),"normalized":t,"normalization_mode":m["mode"],"normalization_reason":m["reason"]})
    return {"service":"Untrapped Update Middleman","version":VERSION,"protocol":PROTOCOL,"baseline":BASELINE,"minimum_baseline":BASELINE,"baseline_enforcement":"client-side","translation":{"json_to_powershell":True,"explicit_source_only":True,"ordinary_json_preserved":True,"base64_supported":True},"cache_ttl":CACHE_TTL,"artifacts":a}
class Handler(BaseHTTPRequestHandler):
    server_version="UntrappedMiddleman/3.1"
    def send_json(self,code,obj):
        b=json.dumps(obj,indent=2).encode(); self.send_response(code); self.send_header("Content-Type","application/json; charset=utf-8"); self.send_header("Cache-Control","no-store"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        try:
            p=unquote(self.path.split("?",1)[0])
            if p=="/health": self.send_json(200,{"ok":True,"service":"Untrapped Update Middleman","version":VERSION,"protocol":PROTOCOL,"baseline":BASELINE,"validation":"transport-level only; client owns PowerShell parser validation"}); return
            if p=="/v1/manifest": self.send_json(200,manifest()); return
            pre="/v1/artifact/"
            if not p.startswith(pre): self.send_json(404,{"error":"not_found"}); return
            name=p[len(pre):]
            if name not in ALLOW: self.send_json(404,{"error":"artifact_not_allowlisted"}); return
            d,t,m=artifact(name); text=d.decode("utf-8","replace") if name.endswith(".ps1") else ""; detected=version_tuple(text) if text else (0,0,0)
            if name.endswith(".ps1"):
                errors=ps_lint(text)
                if errors: self.send_json(422,{"error":"powershell_transport_validation_failed","path":name,"details":errors,"normalization":m}); return
            self.send_response(200); self.send_header("Content-Type","application/octet-stream"); self.send_header("Cache-Control","no-store"); self.send_header("X-Untrapped-SHA256",sha256(d)); self.send_header("X-Untrapped-Input-SHA256",m["input_sha256"]); self.send_header("X-Untrapped-Normalized","true" if t else "false"); self.send_header("X-Untrapped-Normalization-Mode",m["mode"]); self.send_header("X-Untrapped-Normalization-Reason",m["reason"][:240]); self.send_header("X-Untrapped-Baseline",BASELINE); self.send_header("X-Untrapped-Protocol",str(PROTOCOL)); self.send_header("X-Untrapped-Version",dotted(detected)); self.send_header("Content-Length",str(len(d))); self.end_headers(); self.wfile.write(d)
        except TranslationError as ex:self.send_json(422,{"error":"normalization_failed","detail":str(ex)})
        except Exception as ex:self.send_json(502,{"error":"upstream_unavailable","detail":str(ex)})
    def log_message(self,fmt,*args): print("[middleman] "+(fmt%args),flush=True)
if __name__=="__main__":
    print("[middleman] Untrapped Update Middleman",VERSION,"starting on port",PORT,flush=True); print("[middleman] Baseline floor:",BASELINE,"(client-side enforcement)",flush=True); print("[middleman] JSON-to-PowerShell translation: explicit-envelope mode",flush=True); print("[middleman] PowerShell validation: transport checks only; client parser owns syntax validation",flush=True); ThreadingHTTPServer(("0.0.0.0",PORT),Handler).serve_forever()
