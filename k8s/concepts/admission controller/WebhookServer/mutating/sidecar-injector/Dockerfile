FROM python:3.12-slim

WORKDIR /app

# Install python deps first for better layer caching
COPY requirements.txt /app/requirement.txt
RUN pip install --no-cache-dir -r /app/requirement.txt

# Copy webhook server
COPY sidecar-injector.py /app/sidecar-injector.py

# Webhook listens on 8443 in the pod, Service maps 443 -> 8443
EXPOSE 8443

# The TLS cert/key are expected to be mounted at /tls/tls.crt and /tls/tls.key
CMD ["python", "/app/sidecar-injector.py"]
