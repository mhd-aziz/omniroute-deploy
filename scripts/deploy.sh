#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — Deploy OmniRoute via docker compose (EC2 + homelab)
# Dipanggil dari GitHub Actions (self-hosted runner), bisa juga manual di host.
#
# Usage: deploy.sh [IMAGE_TAG] [VERIFY_ONLY] [CLEANUP]
#   IMAGE_TAG   : tag Docker Hub diegosouzapw/omniroute (default: next-web).
#                 JANGAN pakai latest-web — build 27 Ags 2026, lebih tua 3 minggu
#                 dari next-web (17 Sep 2026) yang sedang berjalan di kedua host.
#                 Boleh juga digest sha256:<64hex>.
#   VERIFY_ONLY : true = hanya cek tag + laporan disk, tanpa pull/restart.
#   CLEANUP     : normal (default) = rmi tag omniroute lain + prune dangling.
#                 full            = stop -> backup DB -> HAPUS container -> rmi/prune,
#                                   sehingga containerd GC benar-benar membuang
#                                   snapshot layer image lama (reclaim besar).
#
# BATASAN PENTING (jangan diubah):
#   * Script ini TIDAK pernah mengubah isi docker-compose.yml selain baris `image:`.
#     Blok environment / volumes / command / ports / user / dll TIDAK disentuh.
#   * Volume omniroute-data TIDAK pernah dihapus.
#   * Tidak menulis /etc/docker/daemon.json, tidak restart docker daemon.
# ==============================================================================
set -euo pipefail

TAG="${1:-next-web}"
VERIFY_ONLY="${2:-false}"
CLEANUP="${3:-normal}"

case "$CLEANUP" in
  normal|full) ;;
  *) echo "FATAL: CLEANUP harus 'normal' atau 'full' (diberikan: $CLEANUP)" >&2; exit 1 ;;
esac

# ---------- lokasi compose dir (auto-fallback, EC2 dulu lalu homelab) ----------
if [ -n "${COMPOSE_DIR:-}" ]; then
  :
elif [ -d /home/ubuntu/omniroute ]; then
  COMPOSE_DIR=/home/ubuntu/omniroute
elif [ -d /home/bazyngan/omniroute ]; then
  COMPOSE_DIR=/home/bazyngan/omniroute
else
  COMPOSE_DIR=/home/ubuntu/omniroute
fi

COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
if [[ "$TAG" == sha256:* ]]; then
  IMAGE="diegosouzapw/omniroute@$TAG"
else
  IMAGE="diegosouzapw/omniroute:$TAG"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="$COMPOSE_DIR/docker-compose.yml.bak-$STAMP"
BACKUP_KEEP=5

say() { echo "$*"; }

# sudo hanya kalau benar-benar NOPASSWD (runner tidak punya TTY untuk password)
if sudo -n true 2>/dev/null; then SUDO="sudo"; else SUDO=""; fi

snap_count() {
  if [ -z "$SUDO" ]; then echo "n/a"; return 0; fi
  $SUDO ctr -n moby snapshots ls 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

dir_size() {
  if [ -z "$SUDO" ]; then echo "n/a"; return 0; fi
  $SUDO du -sh "$1" 2>/dev/null | cut -f1 || echo "n/a"
}

free_bytes() { df -B1 --output=avail / | tail -1 | tr -d ' '; }

human_bytes() {
  awk -v b="$1" 'BEGIN{
    neg=""; if (b<0) { neg="-"; b=-b }
    split("B KB MB GB TB",u," "); i=1;
    while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%s%.2f %s", neg, b, u[i]
  }'
}

disk_report() {
  say "----- laporan disk: $1 -----"
  df -h / | tail -1
  say "containerd snapshots: $(snap_count)"
  say "content store: $(dir_size /var/lib/containerd/io.containerd.content.v1.content)"
  say "snapshots dir: $(dir_size /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots)"
  say "volume omniroute-data: $(dir_size /var/lib/docker/volumes/omniroute-data/_data)"
  docker system df 2>/dev/null || true
}

backup_db() {
  local vol out
  vol="$(docker volume inspect omniroute-data --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [ -z "$vol" ] || [ ! -d "$vol" ]; then
    say "WARNING: volume omniroute-data tidak ditemukan — backup DB dilewati"
    return 0
  fi
  out="$COMPOSE_DIR/db-backup-$STAMP.tar.gz"
  say "backup DB: $vol -> $(basename "$out")"
  # tar menulis ke stdout supaya file jadi milik user runner (bukan root)
  if $SUDO tar -czf - -C "$vol" . > "$out" 2>/dev/null || tar -czf - -C "$vol" . > "$out" 2>/dev/null; then
    ls -lh "$out" || true
  else
    say "WARNING: backup DB GAGAL — deploy dilanjutkan tanpa backup (berisiko)"
    rm -f "$out" 2>/dev/null || true
    return 0
  fi
  # retention: simpan 2 backup DB terbaru
  ls -1t "$COMPOSE_DIR"/db-backup-*.tar.gz 2>/dev/null | tail -n +3 | while read -r old; do
    say "  hapus backup DB lama: $(basename "$old")"
    $SUDO rm -f "$old" 2>/dev/null || rm -f "$old" 2>/dev/null || true
  done
}

cleanup_tags() {
  # hapus semua tag omniroute KECUALI image ber-ID yang dilewatkan sebagai argumen.
  # Argumen = daftar ID yang WAJIB dipertahankan (dipisah spasi).
  local keep_ids=" $* " id ref failed=0
  if [ "$keep_ids" = "  " ]; then
    say "  WARNING: tidak ada ID image untuk dipertahankan — cleanup tag dilewati (aman)"
    return 0
  fi
  while read -r id ref; do
    [ -z "${id:-}" ] && continue
    [ "${ref:-}" = "<none>:<none>" ] && continue
    case "$keep_ids" in
      *" $id "*) say "  simpan (masih dipakai/akan dipakai): $ref"; continue ;;
    esac
    if docker rmi "$ref" >/dev/null 2>&1; then
      say "  rmi: $ref"
    else
      say "  GAGAL rmi: $ref"
      failed=$((failed+1))
    fi
  done < <(docker images diegosouzapw/omniroute --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null || true)

  if [ "$failed" -gt 0 ]; then
    say "  HINT: rmi gagal biasanya karena container masih memakai image tsb."
    say "        Pakai cleanup=full agar container dihapus lebih dulu (memicu GC containerd)."
  fi
}

retention_compose_backup() {
  # HANYA dipanggil setelah deploy sukses — kalau gagal, semua backup dibiarkan
  ls -1t "$COMPOSE_DIR"/docker-compose.yml.bak-* 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | while read -r f; do
    say "  hapus backup compose lama: $(basename "$f")"
    rm -f "$f" 2>/dev/null || true
  done
}

# ==============================================================================
say "==> OmniRoute deploy $(date -u +%FT%TZ)"
say "==> Host: $(hostname) | compose dir: $COMPOSE_DIR"
say "==> Image: $IMAGE | verify_only: $VERIFY_ONLY | cleanup: $CLEANUP"

# ---------- 0. preflight ----------
if [ ! -d "$COMPOSE_DIR" ]; then
  echo "FATAL: $COMPOSE_DIR tidak ada. Ini bukan runner omniroute?" >&2
  exit 1
fi
cd "$COMPOSE_DIR"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "FATAL: $COMPOSE_FILE tidak ada" >&2
  exit 1
fi

docker compose config -q || { echo "FATAL: docker-compose.yml invalid" >&2; exit 1; }

say "--- container saat ini ---"
docker ps -a --filter name=omniroute --format '{{.Names}} | {{.Image}} | {{.Status}}' || true
CUR_ID="$(docker inspect -f '{{.Image}}' omniroute 2>/dev/null || true)"
CUR_VER="$(docker exec omniroute node -e "console.log(require('/app/package.json').version)" 2>/dev/null || true)"
say "image id sekarang: ${CUR_ID:-<tidak jalan>} | version: ${CUR_VER:-<n/a>}"

FREE_BEFORE="$(free_bytes)"
SNAP_BEFORE="$(snap_count)"
disk_report "SEBELUM"

# ---------- 1. validasi tag/digest di registry ----------
say "--- cek image di registry ---"
if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  say "OK: $IMAGE ada di Docker Hub"
else
  echo "FATAL: $IMAGE TIDAK ADA di Docker Hub" >&2
  exit 1
fi

if [ "$VERIFY_ONLY" = "true" ]; then
  say "==> VERIFY ONLY — tidak ada perubahan (pull/restart dilewati). Selesai."
  exit 0
fi

# ---------- 2. backup compose + set tag (HANYA baris image) ----------
cp -a "$COMPOSE_FILE" "$BACKUP_FILE"
say "backup: $(basename "$BACKUP_FILE")"

if ! grep -q "image: diegosouzapw/omniroute" "$COMPOSE_FILE"; then
  echo "FATAL: pattern 'image: diegosouzapw/omniroute' tidak ditemukan di compose" >&2
  exit 1
fi

OLD_IMAGE_LINE="$(grep 'image: diegosouzapw/omniroute' "$COMPOSE_FILE" || true)"
if [ "$OLD_IMAGE_LINE" = "    image: $IMAGE" ] || [ "$OLD_IMAGE_LINE" = "image: $IMAGE" ]; then
  say "compose sudah memakai $IMAGE — tidak ada perubahan isi compose"
  rm -f "$BACKUP_FILE"
  COMPOSE_CHANGED=false
else
  # PENTING: hanya baris image: yang diubah. Tidak ada baris lain yang disentuh.
  sed -i "s|image: diegosouzapw/omniroute.*|image: $IMAGE|" "$COMPOSE_FILE"
  say "compose image line -> $(grep 'image: diegosouzapw/omniroute' "$COMPOSE_FILE")"
  COMPOSE_CHANGED=true
  if ! docker compose config -q; then
    echo "FATAL: compose jadi invalid setelah sed — rollback" >&2
    cp -a "$BACKUP_FILE" "$COMPOSE_FILE"
    exit 1
  fi
fi

# ---------- 3. PULL lebih dulu (container lama tetap jalan = nol downtime) ----------
say "--- pull image ---"
if ! docker compose pull omniroute; then
  echo "GAGAL pull. Rollback compose (container lama TIDAK disentuh)..."
  if [ "$COMPOSE_CHANGED" = "true" ] && [ -f "$BACKUP_FILE" ]; then
    cp -a "$BACKUP_FILE" "$COMPOSE_FILE"
  fi
  exit 1
fi

TARGET_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)"
say "image target terpasang: ${TARGET_ID:-<n/a>}"

# smoke test image baru (non-fatal)
SMOKE="$(docker run --rm --entrypoint node "$IMAGE" -e "console.log(require('/app/package.json').version)" 2>/dev/null || true)"
say "versi image baru: ${SMOKE:-<tidak terbaca, lanjut>}"

# ---------- 4. cleanup FULL: stop -> backup DB -> hapus container -> rmi ----------
# Urutan ini WAJIB. `docker rmi`/prune saat container masih memakai image
# tidak membuang snapshot lama — itulah penyebab disk membengkak.
if [ "$CLEANUP" = "full" ]; then
  say "--- cleanup FULL ---"
  docker compose stop omniroute || true
  backup_db
  CID="$(docker inspect -f '{{.Id}}' omniroute 2>/dev/null || true)"
  if [ -n "$CID" ]; then
    docker rm "$CID" >/dev/null && say "container dihapus: $CID"
  else
    say "container tidak ada (sudah terhapus)"
  fi
  say "  snapshots sebelum rmi/prune: $(snap_count)"
  # WAJIB: pertahankan image target (yang baru di-pull) DAN image yang dipakai
  # container sebelum recreate. Kalau ID target tidak terbaca, cleanup tag
  # DILEWATI sama sekali — lebih aman daripada salah hapus.
  if [ -z "$TARGET_ID" ]; then
    say "  WARNING: ID image target tidak terbaca — cleanup tag DILEWATI (aman)"
  else
    cleanup_tags "$TARGET_ID" "$CUR_ID"
  fi
  docker image prune -f 2>&1 | tail -1 || true
  say "  snapshots sesudah rmi/prune: $(snap_count)"
fi

# ---------- 5. up -d (recreate) ----------
say "--- recreate container ---"
if ! docker compose up -d --no-deps omniroute; then
  echo "GAGAL up -d. Rollback compose + recreate..." >&2
  if [ "$COMPOSE_CHANGED" = "true" ] && [ -f "$BACKUP_FILE" ]; then
    cp -a "$BACKUP_FILE" "$COMPOSE_FILE"
  fi
  docker compose pull omniroute >/dev/null 2>&1 || true
  docker compose up -d --no-deps omniroute || echo "ROLLBACK JUGA GAGAL — periksa manual!" >&2
  exit 1
fi

# ---------- 6. tunggu sehat (max ~150s) ----------
for i in $(seq 1 30); do
  H="$(docker inspect --format '{{.State.Health.Status}}' omniroute 2>/dev/null || echo none)"
  say "  health[$i]: $H"
  [ "$H" = "healthy" ] && break
  sleep 5
done

# ---------- 7. verifikasi ----------
say "--- verifikasi ---"
docker ps --filter name=omniroute --format '{{.Names}} | {{.Image}} | {{.Status}}'
NEW_ID="$(docker inspect -f '{{.Image}}' omniroute 2>/dev/null || true)"
NEW_VER="$(docker exec omniroute node -e "console.log(require('/app/package.json').version)" 2>/dev/null || true)"
say "image id akhir: ${NEW_ID:-<n/a>} | version: ${NEW_VER:-<n/a>}"
if [ -n "$CUR_ID" ] && [ "$CUR_ID" = "$NEW_ID" ]; then
  say "CATATAN: image id TIDAK berubah (tag $TAG memang sudah versi terbaru)"
else
  say "CATATAN: image berubah: ${CUR_ID:-<lama>} -> ${NEW_ID:-<baru>}"
fi

LIVE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/livez || true)"
HEALTH="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/healthz || true)"
say "livez: $LIVE | healthz: $HEALTH"

if [ "$LIVE" != "200" ]; then
  echo "WARNING: livez tidak 200 — periksa log container!" >&2
  exit 1
fi

# ---------- 8. cleanup ringan (selalu dijalankan) ----------
# Yang dipertahankan: image yang SEDANG DIPAKAI container (NEW_ID) + image target.
# Kalau keduanya tidak terbaca, cleanup tag dilewati (tidak ada penghapusan buta).
say "--- cleanup: tag omniroute lain + dangling + build cache >72h ---"
if [ -n "$NEW_ID" ] || [ -n "$TARGET_ID" ]; then
  cleanup_tags "$NEW_ID" "$TARGET_ID"
else
  say "  WARNING: ID image tidak terbaca — cleanup tag dilewati (aman)"
fi
docker image prune -f 2>&1 | tail -1 || true
docker builder prune -f --filter until=72h 2>&1 | tail -1 || true

# ---------- 9. retention backup compose (hanya setelah sukses) ----------
say "--- retention backup compose (simpan $BACKUP_KEEP terbaru) ---"
retention_compose_backup

# ---------- 10. laporan akhir ----------
FREE_AFTER="$(free_bytes)"
SNAP_AFTER="$(snap_count)"
disk_report "SESUDAH"

DELTA=$((FREE_AFTER - FREE_BEFORE))
say "=============================================="
say "ruang bebas: $(human_bytes "$FREE_BEFORE") -> $(human_bytes "$FREE_AFTER")  (delta: $(human_bytes "$DELTA"))"
say "containerd snapshots: $SNAP_BEFORE -> $SNAP_AFTER"
say "image omniroute terpasang:"
docker images diegosouzapw/omniroute --format '  {{.Repository}}:{{.Tag}} | {{.ID}} | {{.Size}} | {{.CreatedSince}}' || true
if [ "$CLEANUP" = "normal" ] && [ "$SNAP_AFTER" != "n/a" ] && [ "$SNAP_AFTER" -gt 40 ]; then
  say "CATATAN: snapshot masih banyak ($SNAP_AFTER). Trigger workflow lagi dengan cleanup=full untuk reklaim."
fi
say "==> SELESAI $(date -u +%FT%TZ)"