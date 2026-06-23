FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MIRROR_WEB_ROOT=/srv/mirror/www \
    MIRROR_HTTPDIR=/srv/mirror/www \
    MIRROR_OUTDIR=/srv/mirror/www \
    PYTHON_BIN=python3

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chmod +x /app/scripts/*.sh /app/deploy/*.sh

CMD ["/app/deploy/container-index-loop.sh"]
