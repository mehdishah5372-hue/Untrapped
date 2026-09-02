from pathlib import Path

p = Path('/app/server.py')
s = p.read_text(encoding='utf-8')
old = '''def version_of(data: bytes) -> tuple[int, int, int]:
    text = data.decode("utf-8", "replace")
    match = re.search(
        r"(?im)^(?:#|//).*?ver(?:sion)?\\s+([0-9]+(?:\\.[0-9]+){2})",
        text,
    )
    if not match:
        return (0, 0, 0)
    return tuple(int(x) for x in match.group(1).split("."))
'''
new = '''def version_of(data: bytes) -> tuple[int, int, int]:
    # Only an explicit version marker in the first five non-empty source lines
    # is authoritative. Ordinary comments/strings cannot trigger the guard.
    text = data.decode("utf-8", "replace")
    head = "\\n".join(line for line in text.splitlines() if line.strip())
    head = "\\n".join(head.splitlines()[:5])
    match = re.search(
        r"(?im)^(?:#|//)\\s*.*?\\bver(?:sion)?\\s+([0-9]+(?:\\.[0-9]+){2})\\b.*$",
        head,
    )
    if not match:
        return (0, 0, 0)
    return tuple(int(x) for x in match.group(1).split("."))
'''
if old not in s:
    raise SystemExit('expected version_of block not found')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')
print('patched version marker detection')
