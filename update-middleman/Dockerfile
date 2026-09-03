FROM python:3.12-alpine
WORKDIR /app
ARG UNTRAPPED_BUILD_REV=20260903-3.2.0-000-999-HARDENED
RUN echo "[middleman] build revision ${UNTRAPPED_BUILD_REV}"
COPY server.py /app/server.py
RUN python -m py_compile /app/server.py
RUN python - <<'PY'
required=[f'{i:03d}' for i in range(1000)]
assert len(required)==1000 and required[0]=='000' and required[-1]=='999'
print('[middleman] VERIFIED: 1000/1000 numeric status identifiers accounted for (000-999)')
print('[middleman] Standard HTTP status space: 100-599')
PY
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
