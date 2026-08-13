# Slim, multi-arch (amd64/arm64) Python base for the order generator.
FROM python:3.12-slim

WORKDIR /app

# Install dependencies first so this layer is cached across code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY generate.py .

# Unbuffered output so `docker compose logs` shows progress in real time.
ENV PYTHONUNBUFFERED=1

CMD ["python", "generate.py"]
