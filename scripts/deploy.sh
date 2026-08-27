#!/usr/bin/env bash
# Deploy OmniRoute EC2 via docker compose
# Dipanggil dari GitHub Actions (self-hosted runner di EC2).
# Usage: deploy.sh [IMAGE_TAG] [VERIFY_ONLY]
set -euo pipefail

TAG="${1:-latest-web}"
VERIFY_ONLY="${2:-false}"

COMPOSE_DIR="/home/ubuntu/omniroute"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
IMAGE="diegosouzapw/omniroute:$TAG"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "==> OmniRoute deploy $(date -u +%FT%TZ)"
echo "==> Image: $IMAGE | verify_only: $VERIFY_ONLY"

# ---------- 0. preflight ----------
if [ ! -d "$COMPOSE_DIR" ]; then
  echo "FATAL: $COMPOSE_DIR tidak ada. Ini bukan runner EC2 omniroute?" >&2
  exit 1
fi
cd "$COMPOSE_DIR"

echo "--- container saat ini ---"
docker ps --filter name=omniroute --format '{{.Names}} | {{.Image}} | {{.Status}}' || true
CUR_DIGEST="$(docker inspect omniroute --format '{{.Image}}' 2>/dev/null | cut -c8-19 || true)"
CUR_VER="$(docker exec omniroute node /app/bin/omniroute.mjs --version 2>/dev/null || true)"
echo "current digest(awal): $CUR_DIGEST | version: $CUR_VER"

echo "--- cek tag di registry ---"
if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  echo "OK: tag $TAG ada di Docker Hub"
else
  echo "FATAL: tag $TAG TIDAK ADA di Docker Hub" >&2
  exit 1
fi

if [ "$VERIFY_ONLY" = "true" ]; then
  echo "==> VERIFY ONLY — tidak ada perubahan. Selesai."
  exit 0
fi

# ---------- 1. backup compose ----------
cp -a "$COMPOSE_FILE" "$COMPOSE_DIR/docker-compose.yml.bak-$STAMP"
echo "backup: docker-compose.yml.bak-$STAMP"

# ---------- 2. set image tag ----------
if ! grep -q "image: diegosouzapw/omniroute:" "$COMPOSE_FILE"; then
  echo "FATAL: pattern image omniroute tidak ditemukan di compose" >&2
  exit 1
fi
sed -i "s|image: diegosouzapw/omniroute:.*|image: $IMAGE|" "$COMPOSE_FILE"
echo "compose image line -> $(grep 'image: diegosouzapw/omniroute:' "$COMPOSE_FILE")"

# ---------- 3. pull ----------
if ! docker compose pull omniroute; then
  echo "GAGAL pull. Rollback compose..."
  cp -a "$COMPOSE_DIR/docker-compose.yml.bak-$STAMP" "$COMPOSE_FILE"
  exit 1
fi

# ---------- 4. up -d (recreate kalau image berubah) ----------
if ! docker compose up -d --no-deps omniroute; then
  echo "GAGAL up -d. Rollback ke compose backup + recreate..."
  cp -a "$COMPOSE_DIR/docker-compose.yml.bak-$STAMP" "$COMPOSE_FILE"
  docker compose up -d --no-deps omniroute || echo "ROLLBACK JUGA GAGAL — periksa manual!" >&2
  exit 1
fi

# ---------- 5. tunggu sehat (max ~150s) ----------
for i in $(seq 1 30); do
  H="$(docker inspect --format '{{.State.Health.Status}}' omniroute 2>/dev/null || echo none)"
  echo "  health[$i]: $H"
  [ "$H" = "healthy" ] && break
  sleep 5
done

# ---------- 6. verifikasi akhir ----------
echo "--- verifikasi ---"
docker ps --filter name=omniroute --format '{{.Names}} | {{.Image}} | {{.Status}}'
NEW_DIGEST="$(docker inspect omniroute --format '{{.Image}}' 2>/dev/null | cut -c8-19 || true)"
NEW_VER="$(docker exec omniroute node /app/bin/omniroute.mjs --version 2>/dev/null || true)"
echo "digest(akhir): $NEW_DIGEST | version: $NEW_VER"
LIVE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/livez || true)"
HEALTH="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/healthz || true)"
echo "livez: $LIVE | healthz: $HEALTH"

if [ "$LIVE" != "200" ]; then
  echo "WARNING: livez tidak 200 — periksa log container!" >&2
  exit 1
fi

# ---------- 7. bersihkan image dangling (aman) ----------
docker image prune -f >/dev/null 2>&1 || true

echo "==> SELESAI (backup: docker-compose.yml.bak-$STAMP)"