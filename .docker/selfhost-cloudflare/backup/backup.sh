#!/bin/sh
# Backup de AFFiNE a R2:
#   1. pg_dump a un archivo local del contenedor y validación completa (pg_restore lo lee entero);
#   2. cifrado con age (clave pública BACKUP_AGE_RECIPIENT; la privada nunca está en el servidor);
#   3. subida a r2:$BACKUP_BUCKET/postgres/<db>-<fecha>-k<hash>.dump.age
#   4. copia cifrada de config/private.key en keys/private-<hash>.key.age, que nunca se sobrescribe.
#      <hash> identifica qué private.key corresponde a cada dump.
#
# Si algo falla antes del paso 3 no se sube nada, así que un dump roto nunca
# queda bloqueado por la regla de retención del bucket.
set -eu
set -o pipefail

KEY_FILE=/affine-config/private.key
work=$(mktemp -d /tmp/affine-backup.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

[ -s "$KEY_FILE" ] || {
  echo "[backup] ERROR: no se encontró $KEY_FILE (¿arrancó alguna vez affine_migration?)" >&2
  exit 1
}
key_hash=$(sha256sum "$KEY_FILE" | cut -c1-16)

ts=$(date -u +%Y%m%dT%H%M%SZ)
name="${PGDATABASE}-${ts}-k${key_hash}.dump.age"

echo "[backup] $(date -u '+%F %T') pg_dump ${PGDATABASE}@${PGHOST}"
pg_dump --format=custom --compress=6 --no-password --file="$work/db.dump"

# Lectura completa del dump: detecta archivos truncados (pg_restore --list no basta).
pg_restore --file=/dev/null "$work/db.dump"
size=$(wc -c <"$work/db.dump" | tr -d ' ')
echo "[backup] dump válido: ${size} bytes"

age --encrypt --recipient "$BACKUP_AGE_RECIPIENT" --output "$work/db.dump.age" "$work/db.dump"
rm -f "$work/db.dump"

# copyto verifica tamaño y checksum; si falla no queda ningún objeto a medias.
rclone copyto "$work/db.dump.age" "r2:${BACKUP_BUCKET}/postgres/${name}"
echo "[backup] subido r2:${BACKUP_BUCKET}/postgres/${name}"

key_dest="r2:${BACKUP_BUCKET}/keys/private-${key_hash}.key.age"
existing=$(rclone lsf "$key_dest" 2>/dev/null || true)
if [ -n "$existing" ]; then
  echo "[backup] private.key ya respaldada (keys/private-${key_hash}.key.age)"
else
  age --encrypt --recipient "$BACKUP_AGE_RECIPIENT" --output "$work/private.key.age" "$KEY_FILE"
  rclone copyto "$work/private.key.age" "$key_dest"
  echo "[backup] private.key respaldada en keys/private-${key_hash}.key.age"
fi

key_count=$(rclone lsf "r2:${BACKUP_BUCKET}/keys/" | grep -c '^private-.*\.key\.age$' || true)
if [ "$key_count" -gt 1 ]; then
  echo "[backup] AVISO: hay ${key_count} private.key distintas en keys/. Si no rotaste la clave a propósito, puede que se regenerara (p. ej. al reinstalar sin restaurarla). Cada dump indica en su nombre (-k<hash>) cuál necesita." >&2
fi

echo "[backup] $(date -u '+%F %T') listo"
