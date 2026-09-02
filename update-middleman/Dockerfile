FROM python:3.12-alpine
WORKDIR /app
ARG UNTRAPPED_BUILD_REV=20260902-2300-FIX422-BOTH
RUN echo "[middleman] build revision ${UNTRAPPED_BUILD_REV}"
COPY server.py /app/server.py
# NO 422 HERE: this image must not contain the old server-side 422 delimiter validator.
RUN grep -n "NO 409 HERE" /app/server.py
RUN grep -n "NO 422 HERE" /app/Dockerfile
RUN grep -n "false 422s" /app/server.py
RUN python -m py_compile /app/server.py
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
