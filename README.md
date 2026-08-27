# omniroute-deploy

Repo deploy OmniRoute EC2 via GitHub Actions self-hosted runner.

## Cara pakai

1. Buka https://github.com/mhd-aziz/omniroute-deploy/actions/workflows/deploy.yml
2. Klik **Run workflow**
3. Pilih:
   - `image_tag` — tag `diegosouzapw/omniroute` yang mau dipasang (default `latest-web`)
   - `verify_only` — centang kalau cuma mau cek status tanpa pull/restart
4. Klik **Run workflow** dan tunggu job hijau.

## Yang dilakukan script (deploy.sh)

1. Preflight: cek folder compose `/home/ubuntu/omniroute` + status container
2. Cek tag ada di Docker Hub (`docker manifest inspect`)
3. Backup `docker-compose.yml` (timestamp)
4. Ganti `image:` di compose ke tag yang diminta
5. `docker compose pull omniroute`
6. `docker compose up -d --no-deps omniroute` (recreate hanya kalau image berubah)
7. Tunggu status health `healthy` (max 150 detik)
8. Verifikasi: digest, version (`--version`), `/livez` & `/healthz` (harus 200)
9. `docker image prune -f` (dangling)

Kalau pull/up gagal: compose di-rollback otomatis ke backup dan recreate
ulang. Volume `omniroute-data` (DB) tidak pernah tersentuh.

## Rollback manual

```bash
cd /home/ubuntu/omniroute
# cek backup terbaru
ls -la docker-compose.yml.bak-*
# restore
mv docker-compose.yml.bak-<timestamp> docker-compose.yml
docker compose up -d --no-deps omniroute
```

## Runner

- Nama: `omniroute-ec2`
- Labels: `self-hosted, Linux, X64, omniroute-ec2`
- Lokasi: `/home/ubuntu/actions-runner`
- Service: `actions.runner.mhd-aziz-omniroute-deploy.omniroute-ec2.service`