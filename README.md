# omniroute-deploy

Repo deploy OmniRoute via GitHub Actions **self-hosted runner** ke dua host:

| Target | Host (hostname) | Runner label | Compose dir |
|---|---|---|---|
| `homelab` | `homelab` (.19) | `omniroute-homelab` | `/home/bazyngan/omniroute` |
| `akamai` | `akamai-vm` | `omniroute-akamai` | `/home/ubuntu/omniroute` |
| `all` | keduanya (job paralel) | — | — |

Catatan akamai-vm: OmniRoute listen di **port 20129** (bukan 20128 — port itu
dipakai 9Router di VM yang sama). Akses publik lewat Cloudflare Tunnel
`omniroute-akamai` → `https://omnirouteakamai.zisaltech.site` (unit:
`cloudflared-omniroute-akamai.service`, config: `/etc/cloudflared/config-omniroute-akamai.yml`).
Alamat IP host sengaja **tidak** ditulis di repo publik ini.

Target `ec2` DIHAPUS (2026-09-23): VM EC2 sudah mati/expired dan tidak
digunakan lagi. Runner `omniroute-ec2` di GitHub masih terdaftar tapi offline —
dibiarkan saja; kalau nanti mau deploy ke EC2 lagi, daftarkan runner baru dan
tambahkan kembali job-nya.

Deploy **selalu manual** (`workflow_dispatch`). Sengaja TIDAK ada push trigger,
schedule, atau watcher.

## Cara pakai

1. Buka https://github.com/mhd-aziz/omniroute-deploy/actions/workflows/deploy.yml
2. Klik **Run workflow**, isi:
   - **`image_tag`** — tag `diegosouzapw/omniroute` dari Docker Hub (default `next-web`).
     Boleh tag apa pun (`main-web`, `next-web`, ...) atau digest `sha256:<64hex>`.
     ⚠️ **Jangan menilai freshness dari nama tag.** `latest*` adalah pointer
     mutable yang bisa menunjuk build **berminggu-minggu lebih tua** daripada
     `next*`. Cek dulu field `created` pada config blob amd64 di registry
     (lihat bagian *Cek tag mana yang terbaru*), karena salah tag = downgrade
     diam-diam.
   - **`target`** — `homelab` | `akamai` | `all` (default `akamai`).
     Perhatikan default ini: kalau lupa diubah, hanya satu host yang ter-update.
   - **`cleanup`** — `normal` (default) atau `full` (lihat bagian Pembersihan disk).
   - **`verify_only`** — centang untuk cek tag + laporan disk saja, tanpa pull/restart.
   - **`allow_no_db_backup`** — biarkan tidak dicentang. Centang hanya kalau
     Anda sadar mau lanjut `cleanup=full` walau backup DB gagal.
3. Klik **Run workflow**, tunggu job hijau.

## Arti input `cleanup`

| Nilai | Perilaku | Kapan dipakai |
|---|---|---|
| `normal` (default) | pull → recreate → hapus tag omniroute lain + dangling + build cache >72h | Deploy rutin |
| `full` | pull → stop → **backup DB (wajib)** → hapus container → rmi + prune → recreate | Saat mau reklaim disk |

Alasannya: `docker rmi` / prune **saat container masih memakai image** tidak
membuang snapshot layer lama di containerd. Snapshot itu tetap tertinggal
walau `docker system df` melaporkan `RECLAIMABLE 0B`, dan itulah penyebab
`/var/lib/containerd` membengkak tanpa terlihat. Dengan `cleanup=full`,
container dihapus lebih dulu sehingga GC containerd benar-benar jalan.

**Keamanan DB di mode `full`:** volume DB di-backup ke
`<COMPOSE_DIR>/db-backup-<stamp>.tar.gz` (retention 2 terbaru) **sebelum**
container dihapus. Backup dianggap sah hanya kalau arsipnya non-kosong, bisa
dibaca (`tar -tzf`), dan benar-benar memuat `storage.sqlite`. Kalau gagal,
cleanup dibatalkan: container dihidupkan kembali dan job exit 1 — supaya tidak
ada penghapusan tanpa jaring pengaman. Untuk memaksa lanjut tanpa backup:
input `allow_no_db_backup=true`.

`cleanup=full` me-restart OmniRoute (downtime ±30-60 detik, karena pull
dilakukan lebih dulu di luar jalur kritis dan backup DB menambah ±50 detik
untuk DB 176MB). Di homelab, OmniRoute melayani Hermes (`omnilocal`), jadi
pilih waktunya dengan sadar.

## Yang dilakukan `scripts/deploy.sh`

1. **Validasi input** — bentuk `image_tag`/digest diperiksa lebih dulu
   (`[A-Za-z0-9._-]`, maks 128 char, atau `sha256:<64 hex>`). Nilai aneh
   (spasi, `|`, `&`) ditolak, karena akan merusak `sed` yang menulis baris
   `image:` di compose.
2. **Preflight** — cek compose dir + file, validasi `docker compose config -q`,
   catat status container/digest/versi.
3. **Laporan disk SEBELUM** — `df`, jumlah containerd snapshot, ukuran
   content store + snapshot dir + volume DB, `docker system df`.
4. **Validasi image** — `docker manifest inspect` (tag/digest harus ada).
   Kalau `verify_only=true`, berhenti di sini.
5. **Backup compose** (timestamp), lalu ubah **hanya baris `image:`**.
   Kalau tag sudah sama, compose tidak diubah dan backup sengaja dihapus
   (salinan identik tidak perlu disimpan — jadi "backup hilang" pada redeploy
   tag yang sama itu **normal**, bukan kehilangan data).
6. **Pull** — dijalankan sebelum stop, sehingga kalau pull gagal tidak ada
   downtime. Kalau gagal: compose di-rollback, container lama tidak disentuh.
7. **Smoke test** image baru (baca versi lewat `docker run --rm --network none`),
   non-fatal.
8. **Jika `cleanup=full`** — stop → backup DB (wajib, lihat di atas) → hapus
   container → rmi/prune. Image target dan image yang sedang dipakai selalu
   dipertahankan. Kegagalan `docker rm` dilaporkan eksplisit di log (dulu
   bisa lewat tanpa jejak karena `cmd && say` yang gagal tidak menghentikan
   bash).
9. **Recreate** (`up -d --no-deps`). Kalau gagal: rollback compose + recreate.
10. **Tunggu health** `healthy` (polling 30×5s).
11. **Verifikasi** — status container, image id sebelum/sesudah, versi,
    `/livez` dan `/healthz` (livez ≠ 200 = job gagal). Port probe diambil dari
    port host yang di-publish container dan **hanya port pertama**, supaya
    penambahan port lain di compose tidak membuat probe gagal.
12. **Cleanup ringan** — rmi tag omniroute lain (kecuali yang dipakai) +
    dangling prune + `builder prune --filter until=72h`.
13. **Retention backup compose** — simpan 5 terbaru, diurutkan **berdasarkan
    nama** (stamp = kronologis), bukan mtime: berkas backup dibuat dengan
    `cp -a` sehingga mtime-nya mewarisi file lama dan urutan mtime menyesatkan.
    Hanya berkas ber-stamp digit yang dihitung, jadi backup manual
    (mis. `docker-compose.yml.bak-hermes-<tgl>`) tidak pernah tersentuh.
    **Hanya** dijalankan setelah deploy sukses; kalau gagal semua backup
    dibiarkan utuh.
14. **Laporan disk SESUDAH** + delta ruang bebas + peringatan bila snapshot
    masih >40 (saran menjalankan `cleanup=full`).

## Yang TIDAK pernah dilakukan script

- **Tidak menyentuh isi `docker-compose.yml` selain baris `image:`.**
  Blok `environment`, `volumes`, `command`, `ports`, `user`, dll tidak diapa-apakan.
- Tidak pernah menghapus volume `omniroute-data` (DB).
- Tidak menulis `/etc/docker/daemon.json` dan tidak me-restart docker daemon.
- Tidak menyimpan secret apa pun di repo (repo publik).

## Rollback manual

```bash
cd /home/bazyngan/omniroute      # atau /home/ubuntu/omniroute
ls -la docker-compose.yml.bak-*        # cek backup terbaru
cp -a docker-compose.yml.bak-<stamp> docker-compose.yml
docker compose up -d --no-deps omniroute
```

Kalau butuh image versi lama: jalankan workflow lagi dengan `image_tag`
versi sebelumnya (script akan pull dan recreate).

## Verifikasi image benar-benar terpasang

Nama/digest tag di Docker Hub tidak cukup untuk membuktikan isi image. Langkah
yang bisa dipercaya:

1. Bandingkan **layer**: `docker inspect <image> --format '{{json .RootFS.Layers}}'`
   lokal vs `rootfs.diff_ids` dari config blob manifest amd64 di Docker Hub.
   Harus identik **dan urutannya sama**.
2. Bandingkan `created` pada config blob registry dengan `.Created` image lokal.
3. Cek versi aplikasi di dalam container:
   `docker exec omniroute node -e "console.log(require('/app/package.json').version)"`.

Catatan teknis: `curl` ke `blobs/...` di registry **wajib** pakai `-L`, karena
registry membalas 307 ke CDN. Tanpa `-L` body-nya kosong dan mudah disalahartikan.

## Cek tag mana yang terbaru

```bash
# daftar tag + waktu update terakhir (urut terbaru)
curl -s "https://hub.docker.com/v2/repositories/diegosouzapw/omniroute/tags/?page_size=25&ordering=last_updated" \
  | python3 -c "import json,sys; [print(t['name'].ljust(22), t['last_updated'][:19]) for t in json.load(sys.stdin)['results']]"
```

`next` / `next-web` / `next-bun` / `next-web-bun` dibangun dari run CI yang
sama (urut: base → web → bun-base → bun-web), jadi tag `-bun` yang muncul
"lebih baru" hanya karena selesai belakangan — bukan build berbeda. Varian
`-web` memuat Chromium/Playwright (dibutuhkan provider web-session).

## Kalau disk masih penuh

1. Jalankan workflow `cleanup=full` untuk target yang bersangkutan.
2. Cek laporan disk di log job (SEBELUM vs SESUDAH + jumlah snapshot).
3. `docker system df` yang melaporkan `RECLAIMABLE 0B` **bukan** berarti tidak
   ada sampah — lihat `ctr -n moby snapshots ls` dan `du -sh /var/lib/containerd`.
   Untuk ukuran nyata per image, pakai `docker system df -v` dan baca kolom
   `UNIQUE SIZE` (angka `RECLAIMABLE` di baris Images bisa menyesatkan saat
   image dipakai container yang jalan).
4. `builder prune --filter until=72h` hanya membuang cache build yang lebih tua
   dari 72 jam; kalau cache-nya baru, reclaim-nya 0B (normal).
5. Jangan mengutak-atik `meta.db` atau `rm -rf` store containerd secara manual;
   `ctr snapshots rm` memang selalu gagal `cannot remove snapshot with child`.
   Jalur yang benar adalah hapus image lewat docker → containerd GC bersih sendiri.

## Riwayat perbaikan (audit 2026-10-24)

Audit setelah run `target=all`, `image_tag=next-web`, `cleanup=full` (kedua job
hijau, image terpasang sama di dua host: v3.8.53, digest index
`sha256:9df4d2211ee0…`). Yang diperbaiki:

1. **`cleanup=full` tidak pernah benar-benar membuat backup DB.** Syarat
   `[ -d "$vol" ]` selalu gagal karena `/var/lib/docker` ber-mode
   `drwx--x--- root:root` dan group `docker` tidak bisa menembus path itu —
   log hanya menampilkan "volume omniroute-data tidak ditemukan" lalu lanjut
   menghapus container. Sekarang: syarat direktori dibuang, backup lewat
   `sudo tar` dengan fallback lewat container, arsip diverifikasi
   (non-kosong + `tar -tzf` + memuat `storage.sqlite`), dan **gagal = cleanup
   dibatalkan** (container dihidupkan kembali, exit 1).
2. **Retention backup compose diurutkan dengan mtime** — menyesatkan karena
   `cp -a` mewarisi mtime file lama. Sekarang diurutkan berdasarkan nama
   (stamp) dan hanya menyentuh berkas ber-stamp digit.
3. **Kegagalan `docker rm` hilang tanpa jejak** (bash tidak menghentikan
   `cmd && say` yang gagal, walau `set -e` aktif). Sekarang eksplisit:
   `if rm_out="$(docker rm …)"; then … else WARNING … fi`.
4. **Probe health mengambil SEMUA port host yang di-publish** — kalau compose
   nanti menambah port kedua, nilainya tergabung (mis. `2012820129`) dan job
   gagal walaupun deploy sukses. Sekarang hanya port pertama + disaring digit.
5. **`image_tag` tidak divalidasi.** Input bebas (spasi/`|`/`&`) bisa merusak
   baris `image:` lewat `sed`. Sekarang divalidasi lebih dulu.
6. **Nilai kosong/non-numerik bisa bocor ke `[ -gt ]`/aritmetika** dan
   memunculkan `[: : integer expected` di log. Semua helper disk
   (`snap_count`/`dir_size`/`free_bytes`) sekarang mengembalikan angka valid
   atau `n/a`.
7. **Timeout homelab 20 menit terlalu mepet** — pull `next-web` di homelab
   pernah 15m45s, dan backup DB yang sekarang benar-benar jalan menambah
   ±50s. Homelab → 35 menit, akamai → 25 menit.
8. **Concurrency workflow dikunci per `inputs.target`** sehingga run `all` dan
   run `homelab` masuk grup berbeda dan bisa mengantre dua job untuk host yang
   sama. Sekarang dikunci per host di level job.
9. **Input baru `allow_no_db_backup`** sebagai jalan keluar eksplisit untuk
   fail-safe no. 1.
10. **Dokumentasi**: IP publik akamai dihapus dari README, klaim staleness tag
    yang bertanggal (`latest-web` "27 Ags") diganti cara cek dari registry,
    dan TODO lama soal cleanup tag ditandai selesai (lihat di bawah).

## Status cleanup tag (diperiksa ulang)

Perilaku lama yang dikhawatirkan — "deploy ulang tag yang sama menghapus tag
`next-web` yang sedang dipakai" — **sudah tidak terjadi**: `cleanup_tags`
menerima daftar ID yang harus dipertahankan (image target + image yang dipakai
container) dan log run 2026-10-24 membuktikannya
(`simpan (masih dipakai/akan dipakai): diegosouzapw/omniroute:next-web`).

Sisa batasan yang **disengaja** (bukan bug):

- Image lama yang masih berbagi tag dengan image yang dipakai container akan
  dipertahankan, jadi reclaim layer bisa lebih kecil dari maksimal. Ini pilihan
  sadar: lebih baik kehilangan sebagian reclaim daripada salah menghapus image
  yang sedang dipakai.
- `cleanup=full` mereklaim ±nol kalau memang hanya ada satu image lokal (tidak
  ada layer lama untuk dibuang).

## Runner

- `omniroute-homelab` — lokasi `/home/bazyngan/actions-runner-omniroute`, service
  `actions.runner.mhd-aziz-omniroute-deploy.omniroute-homelab.service`
- `omniroute-akamai` — lokasi `/home/ubuntu/actions-runner-omniroute` (akamai-vm), service
  `actions.runner.mhd-aziz-omniroute-deploy.omniroute-akamai.service`
- Log runner: `/home/<user>/actions-runner*/_diag/Runner*.log`
