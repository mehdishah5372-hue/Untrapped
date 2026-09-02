"""Untrapped Update Middleman 3.0.0 - TRUE BASELINE infrastructure.

The middleman is a read/update broker, not a policy engine. It never changes
Windows networking policy. It only fetches allow-listed repository artifacts,
normalizes explicitly wrapped source, validates the normalized result, and
returns exact SHA-256 metadata.

Important design rule: GET /v1/artifact/* MUST NOT reject an unversioned legacy
PowerShell file with HTTP 409. Baseline protection belongs to the updater,
while the middleman records the detected version for audit. This eliminates
false downgrade detections caused by comments, JSON envelopes, or legacy files.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import unquote
from urllib.request import Request, urlopen

VERSION = "3.0.0"
PROTOCOL = 3
BASELINE = "1.0.0"
MIN_BASELINE = (1, 0, 0)
UPSTREAM = os.environ.get(
    "UNTRAPPED_UPSTREAM",
    "https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/",
)
PORT = int(os.environ.get("PORT", "8080"))
CACHE_TTL = max(0, int(os.environ.get("CACHE_TTL", "30")))
MAX_BYTES = int(os.environ.get("MAX_ARTIFACT_BYTES", str(8 * 1024 * 1024)))

ARTIFACTS = [
    "manifest.json", "background.js", "content.js", "popup.html", "popup.js",
    "bootstrap.bundle.min.js", "assets/untrapped.png", "assets/untrapped.svg",
    "VERSION.txt", "ultra-mode/INSTALL-PACKET-FILTER.ps1",
    "ultra-mode/INSTALL-ULTRA-MODE.ps1", "ultra-mode/config.json",
    "ultra-mode/create-override.ps1", "ultra-mode/generate-keys.ps1",
    "ultra-mode/packet-filter.ps1", "ultra-mode/self-repair.ps1",
    "ultra-mode/status-untrapped.ps1", "ultra-mode/test-untrapped.ps1",
    "ultra-mode/ultra-mode.ps1", "ultra-mode/verify-override.ps1",
]
ALLOW = frozenset(ARTIFACTS)
_cache: dict[str, tuple[float, tuple[bytes, bool, dict[str, Any]]]] = {}
_cache_lock = threading.Lock()


class TranslationError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def version_tuple(text: str) -> tuple[int, int, int]:
    """Detect ONLY an explicit version marker in the first 12 non-empty lines."""
    head = "\n".join([x for x in text.splitlines() if x.strip()][:12])
    # Deliberately require a comment marker and a complete dotted version.
    m = re.search(r"(?im)^(?:#|//)\s*[^\r\n]*?\bver(?:sion)?\s+([0-9]+\.[0-9]+\.[0-9]+)\b", head)
    if not m:
        return (0, 0, 0)
    try:
        return tuple(int(x) for x in m.group(1).split("."))
    except Exception:
        return (0, 0, 0)


def dotted(v: tuple[int, int, int]) -> str:
    return ".".join(map(str, v))


def clean_text(text: str) -> str:
    return text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").strip() + "\n"


def ps_lint(text: str) -> list[str]:
    errors: list[str] = []
    if not text.strip():
        return ["PowerShell payload is empty"]
    if len(text.encode("utf-8")) > MAX_BYTES:
        errors.append("PowerShell payload exceeds size limit")
    if "\x00" in text:
        errors.append("PowerShell payload contains NUL bytes")
    pairs = (("{", "}"), ("(", ")"), ("[", "]"))
    for left, right in pairs:
        if text.count(left) != text.count(right):
            errors.append("PowerShell delimiter count is unbalanced: " + left + right)
    return errors


def json_to_ps(value: Any, indent: int = 0) -> str:
    pad = " " * indent
    if value is None: return "$null"
    if value is True: return "$true"
    if value is False: return "$false"
    if isinstance(value, (int, float)) and not isinstance(value, bool): return str(value).lower()
    if isinstance(value, str): return "'" + value.replace("'", "''") + "'"
    if isinstance(value, list):
        if not value: return "@()"
        return "@(\n" + ",\n".join(" "*(indent+4)+json_to_ps(x, indent+4) for x in value) + "\n" + pad + ")"
    if isinstance(value, dict):
        if not value: return "@{}"
        rows = []
        for k, v in value.items():
            rows.append(" "*(indent+4) + "'" + str(k).replace("'", "''") + "' = " + json_to_ps(v, indent+4))
        return "@{\n" + ";\n".join(rows) + "\n" + pad + "}"
    raise TranslationError("unsupported JSON value")


def decode_payload(value: Any, encoding: str) -> str:
    if not isinstance(value, str):
        raise TranslationError("source payload must be a string")
    if encoding.lower().replace("-", "") == "base64":
        try:
            return base64.b64decode(value, validate=True).decode("utf-8-sig")
        except Exception as exc:
            raise TranslationError("invalid base64 source payload") from exc
    return value


def normalize(raw: bytes, path: str) -> tuple[bytes, bool, dict[str, Any]]:
    meta: dict[str, Any] = {
        "input_sha256": sha256(raw), "output_sha256": sha256(raw),
        "mode": "unchanged", "translated": False, "reason": "already source/text",
    }
    if len(raw) > MAX_BYTES:
        raise TranslationError("artifact exceeds size limit")

    # JSON configuration is data. Preserve it byte-for-byte.
    if path.endswith(".json"):
        try: json.loads(raw.decode("utf-8-sig", "strict"))
        except Exception as exc: raise TranslationError("invalid JSON configuration: " + str(exc)) from exc
        meta["reason"] = "JSON configuration preserved byte-for-byte"
        return raw, False, meta

    text = raw.decode("utf-8-sig", "strict")
    stripped = text.strip()
    if not stripped.startswith(("{", "[", '"')):
        return raw, False, meta

    try:
        obj = json.loads(stripped)
    except Exception:
        meta["reason"] = "not a JSON source wrapper; preserved as source/text"
        return raw, False, meta

    language = ""
    if isinstance(obj, dict):
        language = str(obj.get("language", obj.get("lang", obj.get("target", obj.get("type", ""))))).lower()
    explicit_ps = language in {"powershell", "powershell-script", "powershellscript", "ps1", "pwsh"}

    source: str | None = None
    reason = ""
    if isinstance(obj, str) and path.endswith(".ps1"):
        source = obj
        reason = "top-level JSON string targeted to .ps1"
    elif isinstance(obj, dict):
        encoding = str(obj.get("encoding", obj.get("content_encoding", "")))
        for key in ("powershell", "script", "source", "code", "content", "text", "body"):
            if key in obj:
                value = obj[key]
                if isinstance(value, str):
                    source = decode_payload(value, encoding)
                    reason = "explicit source envelope: " + key
                    break
                if explicit_ps and isinstance(value, (dict, list, int, float, bool)):
                    source = "# JSON-to-PowerShell data translation\n$data = " + json_to_ps(value)
                    reason = "explicit PowerShell data payload: " + key
                    break
                raise TranslationError("source key '" + key + "' must contain text")
        if source is None and explicit_ps and any(k in obj for k in ("commands", "statements")):
            commands = obj.get("commands", obj.get("statements"))
            if not isinstance(commands, list) or not all(isinstance(x, str) for x in commands):
                raise TranslationError("commands/statements must be a list of strings")
            source = "\n".join(x.strip("\r\n") for x in commands)
            reason = "explicit PowerShell command list"
        if source is None and explicit_ps and "data" in obj:
            source = "# JSON-to-PowerShell data translation\n$data = " + json_to_ps(obj["data"])
            reason = "explicit PowerShell data object"
    else:
        meta["reason"] = "ordinary JSON structure; no explicit source envelope"
        return raw, False, meta

    if source is None:
        meta["reason"] = "ordinary JSON structure; no explicit source envelope"
        return raw, False, meta

    if path.endswith(".ps1"):
        source = clean_text(source)
        errors = ps_lint(source)
        if errors: raise TranslationError("; ".join(errors))
        # A generated data literal is inherently PowerShell. For source text,
        # require at least one normal PowerShell marker to catch accidental JSON.
        generated = source.lstrip().startswith("# JSON-to-PowerShell")
        markers = (r"\$[A-Za-z_]", r"\bfunction\s+", r"\b(?:Get|Set|Start|Stop|Test|Invoke|New|Remove|Write)-", r"\[System\.")
        if not generated and not any(re.search(p, source, re.I) for p in markers):
            raise TranslationError("explicit PowerShell payload does not resemble PowerShell")
    else:
        source = clean_text(source)

    out = source.encode("utf-8")
    meta.update({"output_sha256": sha256(out), "mode": "json-envelope-translation", "translated": True, "reason": reason})
    return out, True, meta


def fetch_upstream(path: str) -> bytes:
    req = Request(UPSTREAM + path + "?middleman=" + str(time.time_ns()), headers={"User-Agent": "Untrapped-Middleman/3.0"})
    with urlopen(req, timeout=30) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES: raise TranslationError("upstream artifact exceeds size limit")
    return data


def artifact(path: str) -> tuple[bytes, bool, dict[str, Any]]:
    now = time.time()
    with _cache_lock:
        hit = _cache.get(path)
        if hit and now - hit[0] < CACHE_TTL: return hit[1]
    result = normalize(fetch_upstream(path), path)
    with _cache_lock: _cache[path] = (now, result)
    return result


def manifest() -> dict[str, Any]:
    entries = []
    for path in ARTIFACTS:
        data, translated, meta = artifact(path)
        ver = dotted(version_tuple(data.decode("utf-8", "replace")))
        entries.append({"path": path, "sha256": sha256(data), "bytes": len(data), "version": ver,
                        "normalized": translated, "normalization_mode": meta["mode"],
                        "normalization_reason": meta["reason"], "url": "/v1/artifact/" + path})
    return {"service": "Untrapped Update Middleman", "version": VERSION, "protocol": PROTOCOL,
            "baseline": BASELINE, "minimum_baseline": BASELINE,
            "baseline_enforcement": "client-side; middleman never rejects unversioned legacy PowerShell reads",
            "translation": {"json_to_powershell": True, "explicit_source_only": True,
                             "ordinary_json_preserved": True, "base64_supported": True,
                             "deterministic_data_literals": True, "server_side_basic_lint": True},
            "cache_ttl": CACHE_TTL, "artifacts": entries}


class Handler(BaseHTTPRequestHandler):
    server_version = "UntrappedMiddleman/3.0"

    def send_json(self, code: int, obj: dict[str, Any]) -> None:
        body = json.dumps(obj, indent=2).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_GET(self) -> None:
        try:
            path = unquote(self.path.split("?", 1)[0])
            if path == "/health":
                self.send_json(200, {"ok": True, "service": "Untrapped Update Middleman", "version": VERSION,
                                     "protocol": PROTOCOL, "baseline": BASELINE,
                                     "baseline_enforcement": "client-side", "cache_ttl": CACHE_TTL,
                                     "translation": "JSON-to-PowerShell explicit-envelope normalization enabled"})
                return
            if path == "/v1/manifest": self.send_json(200, manifest()); return
            prefix = "/v1/artifact/"
            if not path.startswith(prefix): self.send_json(404, {"error": "not_found"}); return
            name = path[len(prefix):]
            if name not in ALLOW: self.send_json(404, {"error": "artifact_not_allowlisted"}); return

            data, translated, meta = artifact(name)
            text = data.decode("utf-8", "replace") if name.endswith(".ps1") else ""
            detected = version_tuple(text) if text else (0, 0, 0)
            # NO 409 HERE. Reads are never blocked by an ambiguous/unversioned
            # marker. The client remains responsible for refusing a true downgrade.
            if name.endswith(".ps1"):
                errors = ps_lint(text)
                if errors:
                    self.send_json(422, {"error": "powershell_validation_failed", "path": name, "details": errors, "normalization": meta}); return

            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Untrapped-SHA256", sha256(data))
            self.send_header("X-Untrapped-Input-SHA256", meta.get("input_sha256", ""))
            self.send_header("X-Untrapped-Normalized", "true" if translated else "false")
            self.send_header("X-Untrapped-Normalization-Mode", str(meta.get("mode", "unchanged")))
            self.send_header("X-Untrapped-Normalization-Reason", str(meta.get("reason", ""))[:240])
            self.send_header("X-Untrapped-Baseline", BASELINE)
            self.send_header("X-Untrapped-Protocol", str(PROTOCOL))
            self.send_header("X-Untrapped-Version", dotted(detected))
            self.send_header("X-Untrapped-Baseline-Decision", "allowed-read")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
        except TranslationError as exc:
            self.send_json(422, {"error": "normalization_failed", "detail": str(exc)})
        except Exception as exc:
            self.send_json(502, {"error": "upstream_unavailable", "detail": str(exc)})

    def log_message(self, fmt: str, *args: Any) -> None:
        print("[middleman] " + (fmt % args), flush=True)


if __name__ == "__main__":
    print("[middleman] Untrapped Update Middleman", VERSION, "starting on port", PORT, flush=True)
    print("[middleman] Baseline floor:", BASELINE, "(client-side enforcement)", flush=True)
    print("[middleman] JSON-to-PowerShell translation: explicit-envelope mode", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
