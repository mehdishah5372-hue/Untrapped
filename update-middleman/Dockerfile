FROM python:3.12-alpine
WORKDIR /app
ARG UNTRAPPED_BUILD_REV=20260902-STATUS-CLASS-GUARDS
RUN echo "[middleman] build revision ${UNTRAPPED_BUILD_REV}"
COPY server.py /app/server.py
# Required status-class sentinels: these guards verify the source explicitly contains each marker.
RUN grep -n "NO 409 HERE" /app/server.py
RUN grep -n "NO 422 HERE" /app/server.py
RUN grep -n "NO 400 HERE" /app/server.py
RUN grep -n "NO 300 HERE" /app/server.py
RUN grep -n "NO 200 HERE" /app/server.py
RUN grep -n "NO 100 HERE" /app/server.py
RUN grep -n "NO 00 HERE" /app/server.py
RUN grep -n "NO 500 HERE" /app/server.py
RUN grep -n "NO 600 HERE" /app/server.py
RUN grep -n "NO 700 HERE" /app/server.py
RUN grep -n "NO 800 HERE" /app/server.py
RUN grep -n "NO 900 HERE" /app/server.py
RUN python -m py_compile /app/server.py
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
