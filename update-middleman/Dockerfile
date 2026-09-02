FROM python:3.12-alpine
WORKDIR /app
ARG UNTRAPPED_BUILD_REV=20260902-2150
RUN echo "[middleman] build revision ${UNTRAPPED_BUILD_REV}"
COPY server.py /app/server.py
RUN grep -n "NO 409 HERE" /app/server.py
ENV PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
