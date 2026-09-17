# omniroute-deploy

Repo deploy OmniRoute via GitHub Actions **self-hosted runner** ke dua host:

| Target | Host | Runner label | Compose dir |
|---|---|---|---|
| `ec2` | `omniroute-ec2` (EC2) | `omniroute-ec2` | `/home/ubuntu/omniroute` |
| `homelab` | `homelab` (.19) | `omniroute-homelab` | `/home/bazyngan/omniroute` |
| `both` | keduanya (job paralel) | — | — |

Deploy **selalu manual** (`workflow_dispatch`). Sengaja TIDAK ada push trigger,
schedule, atau watcher.

## Cara pakai

1. Buka https://github.com/mhd-aziz/omniroute-deploy/actions/workflows/deploy.yml
2. Klik **Run workflow**, isi:
   - **`image_tag`** — tag `diegosouzapw/omniroute` dari Docker Hub (default `next-web`).
     Boleh tag apa pun (`main-web`, `next-web`, …) atau digest `sha256:<64hex>`.
     ⚠️ **JANGAN pakai `latest-web`** — tag itu menunjuk build **27 Ags 2026**,
     sementara `next-web` build **17 Sep 2026** (3 minggu lebih baru, dan itu yang
     sedang berjalan di kedua host). Pakai `latest-web` = DOWNGRADE.
   - **`target`** — `ec2` | `homelab` | `both`.
   - **`cleanup`** — `normal` (default) atau `full` (lihat bagian Pembersihan disk).
   - **`verify_only`** — centang untuk cek tag + laporan disk saja, tanpa pull/restart.
3. Klik **Run workflow**, tunggu job hijau.

## Arti input `cleanup`

| Nilai | Perilaku | Kapan dipakai |
|---|---|---|
| `normal` (default) | pull → recreate → hapus tag omniroute lain + dangling + build cache >72h | Deploy rutin |
| `full` | pull → stop → backup DB → **hapus container** → rmi + prune → recreate | Saat mau reklaim disk |

Alasannya: `docker rmi` / prune **saat container masih memakai image** tidak
membuang snapshot layer lama di containerd. Snapshot itu tetap tertinggal
walau `docker system df` melaporkan `RECLAIMABLE 0B`, dan itulah penyebab
`/var/lib/containerd` membengkak tanpa terlihat. Dengan `cleanup=full`,
container dihapus lebih dulu sehingga GC containerd benar-benar jalan.

`cleanup=full` me-restart OmniRoute (downtime ±10-30 detik, karena pull
dilakukan lebih dulu di luar jalur kritis). Di homelab, OmniRoute melayani
Hermes (`omnilocal`), jadi pilih waktunya dengan sadar.

## Yang dilakukan `scripts/deploy.sh`

1. **Preflight** — cek compose dir + file, validasi `docker compose config -q`,
   catat status container/digest/versi.
2. **Laporan disk SEBELUM** — `df`, jumlah containerd snapshot, ukuran
   content store + snapshot dir + volume DB, `docker system df`.
3. **Validasi image** — `docker manifest inspect` (tag/digest harus ada).
   Kalau `verify_only=true`, berhenti di sini.
4. **Backup compose** (timestamp), lalu ubah **hanya baris `image:`**.
   Kalau tag sudah sama, compose tidak diubah dan backup dihapus.
5. **Pull** — dijalankan sebelum stop, sehingga kalau pull gagal tidak ada
   downtime. Kalau gagal: compose di-rollback, container lama tidak disentuh.
6. **Smoke test** image baru (`--version` lewat `docker run --rm`), non-fatal.
7. **Jika `cleanup=full`** — stop → backup DB (tar) → hapus container →
   rmi/prune. Image target dan image yang sedang dipakai selalu dipertahankan.
8. **Recreate** (`up -d --no-deps`). Kalau gagal: rollback compose + recreate.
9. **Tunggu health** `healthy` (polling 30×5s).
10. **Verifikasi** — status container, image id sebelum/sesudah, versi,
    `/livez` dan `/healthz` harus 200 (livez ≠ 200 = job gagal).
11. **Cleanup ringan** — rmi tag omniroute lain (kecuali yang dipakai) +
    dangling prune + `builder prune --filter until=72h`.
12. **Retention backup compose** — simpan 5 terbaru. **Hanya** dijalankan
    setelah deploy sukses; kalau gagal semua backup dibiarkan utuh.
13. **Laporan disk SESUDAH** + delta ruang bebas + peringatan bila snapshot
    masih >40 (saran menjalankan `cleanup=full`).

## Yang TIDAK pernah dilakukan script

- **Tidak menyentuh isi `docker-compose.yml` selain baris `image:`.**
  Blok `environment`, `volumes`, `command`, `ports`, `user`, dll tidak diapa-apakan.
- Tidak pernah menghapus volume `omniroute-data` (DB).
- Tidak menulis `/etc/docker/daemon.json` dan tidak me-restart docker daemon.
- Tidak menyimpan secret apa pun di repo (repo publik).

## Rollback manual

```bash
cd /home/ubuntu/omniroute      # atau /home/bazyngan/omniroute
ls -la docker-compose.yml.bak-*        # cek backup terbaru
cp -a docker-compose.yml.bak-<stamp> docker-compose.yml
docker compose up -d --no-deps omniroute
```

Kalau butuh image versi lama: jalankan workflow lagi dengan `image_tag`
versi sebelumnya (script akan pull dan recreate).

## Verifikasi image benar-benar terpasang

Tag/digest index di Docker Hub sering stale. Yang menentukan adalah **RootFS
layers**: bandingkan `docker inspect <image> --format '{{json .RootFS.Layers}}'`
lokal dengan `rootfs.diff_ids` dari config blob manifest di Docker Hub.
Identik dan urut sama = terbukti. Cek juga `.Created` harus cocok timestamp build.

## Kalau disk masih penuh

1. Jalankan workflow `cleanup=full` untuk target yang bersangkutan.
2. Cek laporan disk di log job (SEBELUM vs SESUDAH + jumlah snapshot).
3. `docker system df` yang melaporkan `RECLAIMABLE 0B` **bukan** berarti tidak
   ada sampah — lihat `ctr -n moby snapshots ls` dan `du -sh /var/lib/containerd`.
4. Jangan mengutak-atik `meta.db` atau `rm -rf` store containerd secara manual;
   `ctr snapshots rm` memang selalu gagal `cannot remove snapshot with child`.
   Jalur yang benar adalah hapus image lewat docker → containerd GC bersih sendiri.

## TODO yang belum diperbaiki

**Step cleanup masih menghapus tag omniroute lain (termasuk `next-web`) dengan
asumsi "tag omniroute lain = versi lama".** Asumsi itu benar untuk UPDATE
(image baru punya id berbeda dari image lama), sehingga id lama memang aman
dibuang. Tapi **salah untuk DEPLOY ULANG TAG YANG SAMA** (mis. tag `next-web`
diulang): container masih memakai image id lama, sehingga yang dibuang justru
tag `next-web` itu sendiri — image next-web hilang dari daftar lokal (reclaim
disk tetap jalan, karena GC memang membersihkan layer lama).

Perbaikan yang benar: hapus HANYA tag yang tidak menunjuk ke id target maupun
id yang sedang dipakai container. Belum di-apply — menunggu keputusan user.

## Runner

- `omniroute-ec2` — lokasi `/home/ubuntu/actions-runner`, service
  `actions.runner.mhd-aziz-omniroute-deploy.omniroute-ec2.service`
- `omniroute-homelab` — lokasi `/home/bazyngan/actions-runner-omniroute`, service
  `actions.runner.mhd-aziz-omniroute-deploy.omniroute-homelab.service`
- Log runner: `/home/<user>/actions-runner*/_diag/Runner*.log`