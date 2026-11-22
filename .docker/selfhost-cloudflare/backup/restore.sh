#!/bin/sh
# Restaura la base de datos de AFFiNE desde un dump guardado en R2.
#
# Detén AFFiNE antes de restaurar (desde la carpeta del compose):
#   docker compose stop affine cloudflared
#   docker compose run --rm backup restore            # el dump más reciente
#   docker compose run --rm backup restore postgres/affine-20261122T070000Z.dump
#   docker compose up -d
#
# Si restauras en un servidor nuevo, recupera también config/private.key:
#   docker compose run --rm --entrypoint rclone -v ./config:/restore backup \
#     copyto r2:affine-backups/config/private.key /restore/private.key
set -eu
set -o pipefail

key="${1:-latest}"
if [ "$key" = "latest" ]; then
  latest=$(rclone lsf "r2:${BACKUP_BUCKET}/postgres/" | grep '\.dump$' | sort | tail -n 1)
  if [ -z "$latest" ]; then
    echo "[restore] ERROR: no hay dumps en r2:${BACKUP_BUCKET}/postgres/" >&2
    exit 1
  fi
  key="postgres/${latest}"
fi

src="r2:${BACKUP_BUCKET}/${key}"
echo "[restore] restaurando ${src} en ${PGDATABASE}@${PGHOST}"
echo "[restore] esto REEMPLAZA los datos actuales de la base de datos."

rclone cat "$src" |
  pg_restore --clean --if-exists --no-owner --exit-on-error --single-transaction \
    --no-password --dbname="$PGDATABASE"

echo "[restore] listo. Arranca de nuevo con: docker compose up -d"
