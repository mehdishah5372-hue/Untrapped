"""Untrapped Update Middleman 1.2.0.

Canonical update broker. It exposes only explicitly allow-listed Untrapped artifacts,
normalizes explicit source envelopes, computes SHA-256 hashes, and enforces the
protected 1.0.0 baseline floor. It never changes a client machine.
"""
from __future__ import annotations
import base64, hashlib, json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote
from urllib.request import Request, urlopen

UPSTREAM = os.environ.get("UNTRAPPED_UPSTREAM", "https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/")
MIN_BASELINE = (1, 0, 0)
PORT = int(os.environ.get("PORT", "8080"))
CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
ARTIFACTS = [
    "manifest.json", "background.js", "content.js", "popup.html", "popup.js", "bootstrap.bundle.min.js",
    "assets/untrapped.png", "assets/untrapped.svg", "VERSION.txt",
    "ultra-mode/INSTALL-PACKET-FILTER.ps1", "ultra-mode/INSTALL-ULTRA-MODE.ps1", "ultra-mode/config.json",
    "ultra-mode/create-override.ps1", "ultra-mode/generate-keys.ps1", "ultra-mode/packet-filter.ps1",
    "ultra-mode/self-repair.ps1", "ultra-mode/status-untrapped.ps1", "ultra-mode/test-untrapped.ps1",
    "ultra-mode/ultra-mode.ps1", "ultra-mode/verify-override.ps1",
]
ALLOW = set(ARTIFACTS)
_cache = {}
_cache_lock = threading.Lock()

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def version_of(data: bytes):
    text = data.decode("utf-8", "replace")
    m = re.search(r"(?im)^(?:#|//).*?ver(?:sion)?\s+([0-9]+(?:\.[0-9]+){2})", text)
    if not m:
        return (0, 0, 0)
    return tuple(int(x) for x in m.group(1).split("."))

def normalize(data: bytes, path: str):
    """Only unwrap explicit source-code envelopes; never reinterpret ordinary JSON configs."""
    if path.endswith(".json"):
        return data, False
    text = data.decode("utf-8", "replace").lstrip("\ufeff").strip()
    if not text.startswith("{"):
        return data, False
    try:
        obj = json.loads(text)
    except Exception:
        return data, False
    if not isinstance(obj, dict):
        return data, False
    for key in ("content", "script", "powershell", "source"):
        value = obj.get(key)
        if not isinstance(value, str):
            continue
        enc = str(obj.get("encoding", obj.get("content_encoding", ""))).lower()
        if enc == "base64":
            return base64.b64decode(value), True
        return value.encode("utf-8"), True
    return data, False

def fetch_upstream(path: str):
    req = Request(UPSTREAM + path + "?middleman=" + str(time.time_ns()), headers={"User-Agent": "Untrapped-Update-Middleman/1.2"})
    with urlopen(req, timeout=30) as r:
        return r.read()

def get_artifact(path: str):
    now = time.time()
    with _cache_lock:
        item = _cache.get(path)
        if item and now - item[0] < CACHE_TTL:
            return item[1]
    raw = fetch_upstream(path)
    native, normalized = normalize(raw, path)
    result = (native, normalized)
    with _cache_lock:
        _cache[path] = (now, result)
    return result

def build_manifest():
    entries = []
    for path in ARTIFACTS:
        native, normalized = get_artifact(path)
        entries.append({"path": path, "sha256": sha256(native), "bytes": len(native), "version": ".".join(map(str, version_of(native))), "normalized": normalized, "url": "/v1/artifact/" + path})
    return {"service": "Untrapped Update Middleman", "protocol": 1, "baseline": "1.0.0", "minimum_baseline": "1.0.0", "generated_at": int(time.time()), "cache_ttl": CACHE_TTL, "artifacts": entries}

class Handler(BaseHTTPRequestHandler):
    server_version = "UntrappedMiddleman/1.2"
    def send_json(self, code, obj):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        try:
            clean = self.path.split("?", 1)[0]
            if clean == "/health":
                self.send_json(200, {"ok": True, "service": "Untrapped Update Middleman", "baseline": "1.0.0", "protocol": 1, "cache_ttl": CACHE_TTL}); return
            if clean == "/v1/manifest":
                self.send_json(200, build_manifest()); return
            prefix = "/v1/artifact/"
            if clean.startswith(prefix):
                path = unquote(clean[len(prefix):])
                if path not in ALLOW:
                    self.send_json(404, {"error": "artifact_not_allowlisted"}); return
                native, normalized = get_artifact(path)
                if path.endswith(".ps1") and version_of(native) < MIN_BASELINE:
                    self.send_json(409, {"error": "baseline_downgrade_refused", "path": path}); return
                self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Cache-Control", "no-store"); self.send_header("X-Untrapped-SHA256", sha256(native)); self.send_header("X-Untrapped-Normalized", "true" if normalized else "false"); self.send_header("X-Untrapped-Baseline", "1.0.0"); self.send_header("X-Untrapped-Cache-TTL", str(CACHE_TTL)); self.send_header("Content-Length", str(len(native))); self.end_headers(); self.wfile.write(native); return
            self.send_json(404, {"error": "not_found"})
        except Exception as exc:
            self.send_json(502, {"error": "upstream_unavailable", "detail": str(exc)})
    def log_message(self, fmt, *args):
        print("[middleman] " + (fmt % args), flush=True)

if __name__ == "__main__":
    print("[middleman] Untrapped Update Middleman starting on port", PORT, flush=True)
    print("[middleman] Baseline floor: 1.0.0; cache TTL:", CACHE_TTL, "seconds", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
