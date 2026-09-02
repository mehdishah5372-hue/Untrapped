FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
COPY .railway-patch-2.0.1.py /app/.railway-patch-2.0.1.py
ENV PORT=8080
EXPOSE 8080
CMD ["sh", "-c", "python /app/.railway-patch-2.0.1.py && python /app/server.py"]
