FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# ffmpeg carries ffprobe too, which smoke_download.py needs to report the codec.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

# A JavaScript runtime for YouTube's player challenges (spec section 3.6).
# Without one yt-dlp warns that extraction is deprecated and some formats go
# missing; Deno is the runtime yt-dlp supports. Pinned by version *and* by
# checksum: "latest" would make the image neither reproducible nor verifiable,
# and this binary is fetched from outside the distro's package signing.
# Unpacked with the Python already in the base image, so no build-only apt
# packages are added; `deno --version` at the end fails the build on a bad one.
ARG DENO_VERSION=2.9.7
ARG DENO_ZIP_SHA256=c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490
RUN set -eux; \
    url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-x86_64-unknown-linux-gnu.zip"; \
    python -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], '/tmp/deno.zip')" "$url"; \
    echo "${DENO_ZIP_SHA256}  /tmp/deno.zip" | sha256sum -c -; \
    python -c "import zipfile; zipfile.ZipFile('/tmp/deno.zip').extract('deno', '/usr/local/bin')"; \
    chmod 0755 /usr/local/bin/deno; \
    rm /tmp/deno.zip; \
    deno --version

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
# The [default] extra carries yt-dlp-ejs, the JavaScript the Deno runtime above
# executes to solve player challenges. Its version has to match what this
# yt-dlp pins, so the extra resolves it; pinning it here would drift.
CMD pip install --no-cache-dir -U 'yt-dlp[default]' \
      || echo "WARNING: yt-dlp self-update failed; continuing with the image version" \
    ; exec python -m uvicorn app.main:app \
        --host "${PRISMA_HOST:-0.0.0.0}" \
        --port "${PRISMA_PORT:-8000}"
