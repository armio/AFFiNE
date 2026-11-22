#!/bin/sh
# Hace un pg_dump (formato custom, comprimido) y lo sube a R2 sin tocar disco.
# También copia config/private.key, necesaria para restaurar en otro servidor.
set -eu
set -o pipefail

ts=$(date -u +%Y%m%dT%H%M%SZ)
key="postgres/${PGDATABASE}-${ts}.dump"
dest="r2:${BACKUP_BUCKET}/${key}"

echo "[backup] $(date -u '+%F %T') pg_dump ${PGDATABASE}@${PGHOST} -> ${dest}"
pg_dump --format=custom --compress=6 --no-password | rclone rcat "$dest"

size=$(rclone size --json "$dest" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
if [ -z "$size" ] || [ "$size" -lt 1024 ]; then
  echo "[backup] ERROR: el dump subido parece vacío (${size:-0} bytes)." >&2
  exit 1
fi
echo "[backup] dump subido: ${size} bytes"

if [ -f /affine-config/private.key ]; then
  rclone copyto /affine-config/private.key "r2:${BACKUP_BUCKET}/config/private.key"
  echo "[backup] config/private.key copiada"
else
  echo "[backup] AVISO: no se encontró /affine-config/private.key" >&2
fi

echo "[backup] $(date -u '+%F %T') listo"
