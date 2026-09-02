"""Untrapped Update Middleman 2.0.0.

A conservative, deterministic update broker for Untrapped.

Key guarantees:
- only explicitly allow-listed artifacts can be fetched;
- JSON configuration files are preserved exactly;
- JSON source envelopes can be decoded into PowerShell/JS/text when the target
  artifact explicitly identifies the source language or the destination is .ps1;
- several common JSON representations are normalized without inventing network
  policy or Windows configuration changes;
- normalized bytes are hashed after translation and returned with verification
  metadata;
- the 1.0.0 baseline floor remains protected for versioned PowerShell artifacts;
- ordinary JSON is never silently converted into PowerShell.
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

UPSTREAM = os.environ.get(
    "UNTRAPPED_UPSTREAM",
    "https://raw.githubusercontent.com/mehdishah5372-hue/Untrapped/main/",
)
MIN_BASELINE = (1, 0, 0)
PROTOCOL = 2
VERSION = "2.0.0"
PORT = int(os.environ.get("PORT", "8080"))
CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
MAX_ARTIFACT_BYTES = int(os.environ.get("MAX_ARTIFACT_BYTES", str(8 * 1024 * 1024)))

ARTIFACTS = [
    "manifest.json",
    "background.js",
    "content.js",
    "popup.html",
    "popup.js",
    "bootstrap.bundle.min.js",
    "assets/untrapped.png",
    "assets/untrapped.svg",
    "VERSION.txt",
    "ultra-mode/INSTALL-PACKET-FILTER.ps1",
    "ultra-mode/INSTALL-ULTRA-MODE.ps1",
    "ultra-mode/config.json",
    "ultra-mode/create-override.ps1",
    "ultra-mode/generate-keys.ps1",
    "ultra-mode/packet-filter.ps1",
    "ultra-mode/self-repair.ps1",
    "ultra-mode/status-untrapped.ps1",
    "ultra-mode/test-untrapped.ps1",
    "ultra-mode/ultra-mode.ps1",
    "ultra-mode/verify-override.ps1",
]
ALLOW = set(ARTIFACTS)

_cache: dict[str, tuple[float, tuple[bytes, bool, dict[str, Any]]]] = {}
_cache_lock = threading.Lock()


class TranslationError(ValueError):
    """Raised when a JSON representation cannot be safely normalized."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def version_of(data: bytes) -> tuple[int, int, int]:
    text = data.decode("utf-8", "replace")
    match = re.search(
        r"(?im)^(?:#|//).*?ver(?:sion)?\s+([0-9]+(?:\.[0-9]+){2})",
        text,
    )
    if not match:
        return (0, 0, 0)
    return tuple(int(x) for x in match.group(1).split("."))


def dotted_version(value: tuple[int, int, int]) -> str:
    return ".".join(str(x) for x in value)


def clean_text(value: str) -> str:
    return value.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").strip() + "\n"


def looks_like_powershell(text: str) -> bool:
    markers = [
        r"\$[A-Za-z_][A-Za-z0-9_]*",
        r"\bparam\s*\(",
        r"\bfunction\s+[A-Za-z_][A-Za-z0-9_-]*",
        r"\b(?:Get|Set|Start|Stop|Test|Invoke|New|Remove|Copy|Move|Write)-[A-Za-z]",
        r"\[System\.",
        r"\[Security\.",
        r"\$env:",
    ]
    return any(re.search(pattern, text, re.I) for pattern in markers)


def basic_powershell_lint(text: str) -> list[str]:
    """Cheap server-side safety/lint checks independent of PowerShell availability."""
    errors: list[str] = []
    if not text.strip():
        errors.append("translated PowerShell is empty")
        return errors
    if len(text.encode("utf-8")) > MAX_ARTIFACT_BYTES:
        errors.append("translated PowerShell exceeds artifact size limit")
    if "\x00" in text:
        errors.append("translated PowerShell contains NUL bytes")
    if text.count("{") != text.count("}"):
        errors.append("PowerShell brace count is unbalanced")
    if text.count("(") != text.count(")"):
        errors.append("PowerShell parenthesis count is unbalanced")
    if text.count("[") != text.count("]"):
        errors.append("PowerShell bracket count is unbalanced")
    return errors


def decode_json_text(raw: bytes) -> Any:
    text = raw.decode("utf-8-sig", "strict").strip()
    if not text:
        raise TranslationError("JSON source is empty")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise TranslationError("invalid JSON: " + str(exc)) from exc


def decode_payload(value: Any, encoding: str = "") -> str:
    if not isinstance(value, str):
        raise TranslationError("source payload is not a string")
    if encoding.lower().replace("-", "") == "base64":
        try:
            return base64.b64decode(value, validate=True).decode("utf-8-sig")
        except Exception as exc:
            raise TranslationError("invalid base64 source payload") from exc
    return value


def json_value_to_powershell(value: Any, indent: int = 0) -> str:
    """Deterministically render JSON data as a PowerShell literal.

    This is deliberately a data-to-literal translator, not an arbitrary command
    generator. It is used only when an envelope explicitly asks for PowerShell
    and contains a data object rather than source text.
    """
    pad = " " * indent
    if value is None:
        return "$null"
    if value is True:
        return "$true"
    if value is False:
        return "$false"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    if isinstance(value, list):
        if not value:
            return "@()"
        inner = ",\n".join(" " * (indent + 4) + json_value_to_powershell(v, indent + 4) for v in value)
        return "@(\n" + inner + "\n" + pad + ")"
    if isinstance(value, dict):
        if not value:
            return "@{}"
        rows = []
        for key, item in value.items():
            key_text = str(key).replace("'", "''")
            rows.append(" " * (indent + 4) + "'" + key_text + "' = " + json_value_to_powershell(item, indent + 4))
        return "@{\n" + ";\n".join(rows) + "\n" + pad + "}"
    raise TranslationError("unsupported JSON value type")


def extract_explicit_source(obj: dict[str, Any]) -> tuple[str | None, bool, str]:
    """Return (source text, translated, reason).

    The order is intentional. Explicit source/code keys win. A plain JSON object
    is only rendered as a PowerShell data literal when an explicit language/target
    marker requests it. This prevents config.json from becoming executable code.
    """
    encoding = str(obj.get("encoding", obj.get("content_encoding", "")))
    language = str(
        obj.get("language", obj.get("lang", obj.get("type", obj.get("target", ""))))
    ).lower()
    explicit_ps = language in {
        "powershell",
        "powershell-script",
        "powershellscript",
        "ps1",
        "pwsh",
    }

    source_keys = ("powershell", "script", "source", "code", "content", "text", "body")
    for key in source_keys:
        if key in obj:
            value = obj[key]
            if isinstance(value, str):
                text = decode_payload(value, encoding)
                return clean_text(text), True, "explicit source envelope"
            if explicit_ps and isinstance(value, (dict, list, int, float, bool)):
                rendered = json_value_to_powershell(value)
                return clean_text("# JSON-to-PowerShell data translation\n$data = " + rendered), True, "explicit PowerShell data payload"
            raise TranslationError("source key '" + key + "' must contain text")

    if explicit_ps and any(k in obj for k in ("commands", "statements")):
        commands = obj.get("commands", obj.get("statements"))
        if not isinstance(commands, list) or not all(isinstance(x, str) for x in commands):
            raise TranslationError("commands/statements must be a list of strings")
        rendered = "\n".join(clean_text(x).rstrip("\n") for x in commands)
        return clean_text(rendered), True, "explicit PowerShell command list"

    if explicit_ps and "data" in obj:
        rendered = json_value_to_powershell(obj["data"])
        return clean_text("# JSON-to-PowerShell data translation\n$data = " + rendered), True, "explicit PowerShell data object"

    return None, False, "no explicit source representation"


def normalize(data: bytes, path: str) -> tuple[bytes, bool, dict[str, Any]]:
    """Normalize an upstream artifact and produce an audit record."""
    meta: dict[str, Any] = {
        "mode": "unchanged",
        "input_sha256": sha256(data),
        "output_sha256": sha256(data),
        "translated": False,
        "reason": "not applicable",
    }

    if len(data) > MAX_ARTIFACT_BYTES:
        raise TranslationError("artifact exceeds size limit")

    # JSON configuration files are never converted, regardless of their contents.
    if path.endswith(".json"):
        try:
            decode_json_text(data)
        except TranslationError:
            # Preserve upstream bytes so a malformed canonical JSON artifact is
            # reported as malformed rather than silently rewritten.
            meta["reason"] = "JSON preserved unchanged; validation failed"
            return data, False, meta
        meta["reason"] = "JSON configuration preserved unchanged"
        return data, False, meta

    stripped = data.decode("utf-8", "replace").lstrip("\ufeff").strip()
    if not stripped.startswith(("{", "[", '"')):
        meta["reason"] = "artifact is already source/text"
        return data, False, meta

    try:
        obj = json.loads(stripped)
    except Exception:
        meta["reason"] = "not valid JSON; preserved as source/text"
        return data, False, meta

    # A top-level JSON string is a safe source envelope only for a .ps1 target.
    if isinstance(obj, str) and path.endswith(".ps1"):
        translated = clean_text(obj)
        errors = basic_powershell_lint(translated)
        if errors:
            raise TranslationError("; ".join(errors))
        meta.update({
            "mode": "json-string-to-powershell",
            "translated": True,
            "reason": "top-level JSON string targeted to .ps1",
        })
        meta["output_sha256"] = sha256(translated.encode("utf-8"))
        return translated.encode("utf-8"), True, meta

    if not isinstance(obj, dict):
        meta["reason"] = "ordinary JSON structure; no explicit source envelope"
        return data, False, meta

    source, translated, reason = extract_explicit_source(obj)
    if source is None:
        meta["reason"] = reason
        return data, False, meta

    if path.endswith(".ps1"):
        errors = basic_powershell_lint(source)
        if errors:
            raise TranslationError("; ".join(errors))
        if not looks_like_powershell(source):
            # Data literals are intentionally accepted; arbitrary prose is not.
            if not source.lstrip().startswith("# JSON-to-PowerShell"):
                raise TranslationError("explicit PowerShell payload does not resemble PowerShell")
    else:
        # For non-.ps1 targets we only unwrap an explicit source envelope. We do
        # not attempt cross-language conversion because that would be speculative.
        if not translated:
            return data, False, meta

    output = source.encode("utf-8")
    meta.update({
        "mode": "json-envelope-translation",
        "translated": True,
        "reason": reason,
        "output_sha256": sha256(output),
    })
    return output, True, meta


def fetch_upstream(path: str) -> bytes:
    req = Request(
        UPSTREAM + path + "?middleman=" + str(time.time_ns()),
        headers={"User-Agent": "Untrapped-Update-Middleman/2.0.0"},
    )
    with urlopen(req, timeout=30) as response:
        data = response.read(MAX_ARTIFACT_BYTES + 1)
        if len(data) > MAX_ARTIFACT_BYTES:
            raise TranslationError("upstream artifact exceeds size limit")
        return data


def get_artifact(path: str) -> tuple[bytes, bool, dict[str, Any]]:
    now = time.time()
    with _cache_lock:
        item = _cache.get(path)
        if item and now - item[0] < CACHE_TTL:
            return item[1]
    raw = fetch_upstream(path)
    normalized, translated, meta = normalize(raw, path)
    result = (normalized, translated, meta)
    with _cache_lock:
        _cache[path] = (now, result)
    return result


def build_manifest() -> dict[str, Any]:
    entries = []
    for path in ARTIFACTS:
        data, translated, meta = get_artifact(path)
        version = version_of(data)
        entries.append({
            "path": path,
            "sha256": sha256(data),
            "bytes": len(data),
            "version": dotted_version(version),
            "normalized": translated,
            "normalization_mode": meta.get("mode", "unchanged"),
            "normalization_reason": meta.get("reason", ""),
            "url": "/v1/artifact/" + path,
        })
    return {
        "service": "Untrapped Update Middleman",
        "version": VERSION,
        "protocol": PROTOCOL,
        "baseline": "1.0.0",
        "minimum_baseline": "1.0.0",
        "translation": {
            "json_to_powershell": True,
            "explicit_source_only": True,
            "ordinary_json_preserved": True,
            "base64_supported": True,
            "deterministic_data_literals": True,
            "server_side_basic_lint": True,
        },
        "generated_at": int(time.time()),
        "cache_ttl": CACHE_TTL,
        "artifacts": entries,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "UntrappedMiddleman/2.0.0"

    def send_json(self, code: int, obj: dict[str, Any]) -> None:
        body = json.dumps(obj, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        try:
            clean = self.path.split("?", 1)[0]
            if clean == "/health":
                self.send_json(200, {
                    "ok": True,
                    "service": "Untrapped Update Middleman",
                    "version": VERSION,
                    "baseline": "1.0.0",
                    "protocol": PROTOCOL,
                    "cache_ttl": CACHE_TTL,
                    "translation": "JSON-to-PowerShell explicit-envelope normalization enabled",
                })
                return

            if clean == "/v1/manifest":
                self.send_json(200, build_manifest())
                return

            prefix = "/v1/artifact/"
            if clean.startswith(prefix):
                path = unquote(clean[len(prefix):])
                if path not in ALLOW:
                    self.send_json(404, {"error": "artifact_not_allowlisted"})
                    return

                data, translated, meta = get_artifact(path)
                declared_version = version_of(data)
                if (
                    path.endswith(".ps1")
                    and declared_version != (0, 0, 0)
                    and declared_version < MIN_BASELINE
                ):
                    self.send_json(409, {
                        "error": "baseline_downgrade_refused",
                        "path": path,
                        "declared_version": dotted_version(declared_version),
                        "minimum_baseline": "1.0.0",
                    })
                    return

                if path.endswith(".ps1") and translated:
                    lint_errors = basic_powershell_lint(data.decode("utf-8", "replace"))
                    if lint_errors:
                        self.send_json(422, {
                            "error": "powershell_translation_failed_validation",
                            "path": path,
                            "details": lint_errors,
                            "normalization": meta,
                        })
                        return

                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Untrapped-SHA256", sha256(data))
                self.send_header("X-Untrapped-Input-SHA256", meta.get("input_sha256", ""))
                self.send_header("X-Untrapped-Normalized", "true" if translated else "false")
                self.send_header("X-Untrapped-Normalization-Mode", str(meta.get("mode", "unchanged")))
                self.send_header("X-Untrapped-Baseline", "1.0.0")
                self.send_header("X-Untrapped-Protocol", str(PROTOCOL))
                self.send_header("X-Untrapped-Cache-TTL", str(CACHE_TTL))
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return

            self.send_json(404, {"error": "not_found"})
        except TranslationError as exc:
            self.send_json(422, {
                "error": "normalization_failed",
                "detail": str(exc),
            })
        except Exception as exc:
            self.send_json(502, {
                "error": "upstream_unavailable",
                "detail": str(exc),
            })

    def log_message(self, fmt: str, *args: Any) -> None:
        print("[middleman] " + (fmt % args), flush=True)


if __name__ == "__main__":
    print("[middleman] Untrapped Update Middleman", VERSION, "starting on port", PORT, flush=True)
    print("[middleman] Baseline floor: 1.0.0; cache TTL:", CACHE_TTL, "seconds", flush=True)
    print("[middleman] JSON-to-PowerShell translation: explicit-envelope mode", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
