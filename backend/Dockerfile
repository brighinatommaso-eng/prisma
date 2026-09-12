FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ffmpeg carries ffprobe too, which smoke_download.py needs to report the codec.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY scripts ./scripts

EXPOSE 8000

# Spec section 3.6: yt-dlp breaks without warning whenever YouTube changes
# something server-side, so it is updated on every start, before uvicorn.
# A failed update (server offline, PyPI unreachable) must not brick the API,
# so it is tolerated and logged — /health then reports the stale version.
CMD pip install --no-cache-dir -U yt-dlp \
      || echo "WARNING: yt-dlp self-update failed; continuing with the image version" \
    ; exec python -m uvicorn app.main:app \
        --host "${PRISMA_HOST:-0.0.0.0}" \
        --port "${PRISMA_PORT:-8000}"
