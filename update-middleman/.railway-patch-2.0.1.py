from pathlib import Path
p=Path('/app/server.py')
s=p.read_text(encoding='utf-8')
start=s.index('def version_of(data: bytes) -> tuple[int, int, int]:')
end=s.index('\n\ndef dotted_version', start)
new='''def version_of(data: bytes) -> tuple[int, int, int]:
    # Only explicit version markers in the first five non-empty source lines
    # are authoritative for baseline protection.
    text = data.decode("utf-8", "replace")
    head_lines = [line for line in text.splitlines() if line.strip()][:5]
    head = "\\n".join(head_lines)
    match = re.search(r"(?im)^(?:#|//)\\s*.*?\\bver(?:sion)?\\s+([0-9]+(?:\\.[0-9]+){2})\\b.*$", head)
    if not match:
        return (0, 0, 0)
    return tuple(int(x) for x in match.group(1).split('.'))
'''
p.write_text(s[:start]+new+s[end:],encoding='utf-8')
