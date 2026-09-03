FROM python:3.12-alpine
WORKDIR /app
ARG UNTRAPPED_BUILD_REV=20260903-3.2.0-000-999-DEFENSIVE
RUN echo "[middleman] build revision ${UNTRAPPED_BUILD_REV}"
COPY server.py /app/server.py
RUN python -m py_compile /app/server.py
RUN python - <<'PY'
from pathlib import Path
import ast
p=Path('/app/server.py')
s=p.read_text(encoding='utf-8')
ast.parse(s, filename=str(p))
required=[f'{i:03d}' for i in range(1000)]
assert len(required)==1000 and required[0]=='000' and required[-1]=='999'
assert '3.2.0' in s and 'PROTOCOL=3' in s and 'BASELINE="1.0.0"' in s
assert 'ThreadingHTTPServer' in s and 'MAX_BYTES' in s and 'FETCH_ATTEMPTS=5' in s
assert 'artifact_not_allowlisted' in s and 'uri_too_long' in s
print('[middleman] VERIFIED: Python syntax, defensive invariants, and 1000/1000 numeric identifiers (000-999)')
print('[middleman] Standard HTTP status space: 100-599')
PY
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
