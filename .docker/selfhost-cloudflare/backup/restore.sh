#!/bin/sh
# Restauración desde R2. Se invoca a través de entrypoint.sh:
#
#   restore <latest|NOMBRE>      restaura la base de datos
#   restore-key <latest|NOMBRE>  recupera la private.key que corresponde a ese dump
#
# Ambos necesitan la clave privada age montada en /run/secrets/age-identity.
# Ejemplos (desde la carpeta del compose, con AFFiNE detenido):
#   docker compose stop affine cloudflared
#   docker compose run --rm -v ~/age-identity.txt:/run/secrets/age-identity:ro backup restore latest
#   docker compose up -d
#
# La base se restaura en una base NUEVA (<db>_restore) y solo si todo sale bien
# se intercambia con la actual, que queda como <db>_pre_restore. Así un dump
# antiguo no deja tablas huérfanas de migraciones posteriores, y un fallo a
# mitad de camino no toca la base en uso.
set -eu
set -o pipefail

IDENTITY_FILE="${BACKUP_AGE_IDENTITY_FILE:-/run/secrets/age-identity}"
# Sin avisos NOTICE de "does not exist, skipping".
export PGOPTIONS="-c client_min_messages=warning"
DB="${PGDATABASE:-affine}"
PATTERN="^${DB}-[0-9]{8}T[0-9]{6}Z-k[0-9a-f]{16}\.dump\.age\$"

die() {
  echo "[restore] ERROR: $*" >&2
  exit 1
}

mode="${1:-}"
arg="${2:-}"

list_dumps() {
  rclone lsf "r2:${BACKUP_BUCKET}/postgres/" | grep -E "$PATTERN" | sort || true
}

resolve_dump() {
  if [ -z "$arg" ]; then
    echo "Dumps disponibles (los más recientes al final):" >&2
    list_dumps | tail -n 10 >&2
    die "indica 'latest' o el nombre exacto del dump"
  fi
  if [ "$arg" = "latest" ]; then
    name=$(list_dumps | tail -n 1)
    [ -n "$name" ] || die "no hay dumps válidos en r2:${BACKUP_BUCKET}/postgres/"
  else
    name=$(basename "$arg")
    echo "$name" | grep -Eq "$PATTERN" || die "nombre de dump no válido: $name"
  fi
  echo "$name"
}

work=$(mktemp -d /tmp/affine-restore.XXXXXX)
trap 'rm -rf "$work"' EXIT INT TERM

case "$mode" in
  db)
    name=$(resolve_dump)
    tmpdb="${DB}_restore"
    olddb="${DB}_pre_restore"
    echo "[restore] descargando postgres/${name}"
    rclone copyto "r2:${BACKUP_BUCKET}/postgres/${name}" "$work/db.dump.age"
    age --decrypt --identity "$IDENTITY_FILE" --output "$work/db.dump" "$work/db.dump.age" ||
      die "no se pudo descifrar (¿clave age incorrecta?)"
    rm -f "$work/db.dump.age"
    pg_restore --file=/dev/null "$work/db.dump" || die "el dump está dañado"

    echo "[restore] restaurando en una base nueva: ${tmpdb}"
    psql -q -v ON_ERROR_STOP=1 -d postgres \
      -c "DROP DATABASE IF EXISTS \"${tmpdb}\" WITH (FORCE)" \
      -c "CREATE DATABASE \"${tmpdb}\""
    pg_restore --no-owner --exit-on-error --single-transaction --no-password \
      --dbname="$tmpdb" "$work/db.dump" || {
      psql -q -d postgres -c "DROP DATABASE IF EXISTS \"${tmpdb}\" WITH (FORCE)" || true
      die "pg_restore falló; la base ${DB} no se modificó"
    }

    echo "[restore] intercambiando ${tmpdb} -> ${DB} (la actual queda como ${olddb})"
    exists=$(psql -tA -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '${DB}'")
    psql -q -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS \"${olddb}\" WITH (FORCE)"
    if [ "$exists" = "1" ]; then
      psql -q -v ON_ERROR_STOP=1 -d postgres >/dev/null \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}' AND pid <> pg_backend_pid()" \
        -c "ALTER DATABASE \"${DB}\" RENAME TO \"${olddb}\""
    fi
    psql -q -v ON_ERROR_STOP=1 -d postgres -c "ALTER DATABASE \"${tmpdb}\" RENAME TO \"${DB}\""

    key_hash=$(echo "$name" | sed -n 's/.*-k\([0-9a-f]\{16\}\)\.dump\.age$/\1/p')
    echo "[restore] listo: ${DB} restaurada desde ${name}"
    echo "[restore] Este dump usa la private.key con hash ${key_hash}. Si config/private.key no es esa"
    echo "[restore] (sha256sum config/private.key | cut -c1-16), recupérala con 'restore-key ${name}'."
    echo "[restore] Cuando compruebes que todo está bien, borra la copia anterior:"
    echo "[restore]   docker compose exec postgres dropdb -U ${PGUSER} ${olddb}"
    ;;

  key)
    [ -d /restore ] || die "monta la carpeta config en /restore: -v ./config:/restore"
    name=$(resolve_dump)
    key_hash=$(echo "$name" | sed -n 's/.*-k\([0-9a-f]\{16\}\)\.dump\.age$/\1/p')
    src="r2:${BACKUP_BUCKET}/keys/private-${key_hash}.key.age"
    echo "[restore] descargando keys/private-${key_hash}.key.age (para ${name})"
    rclone copyto "$src" "$work/private.key.age" || die "no existe ${src}"
    umask 077
    age --decrypt --identity "$IDENTITY_FILE" --output "$work/private.key" "$work/private.key.age" ||
      die "no se pudo descifrar (¿clave age incorrecta?)"
    got=$(sha256sum "$work/private.key" | cut -c1-16)
    [ "$got" = "$key_hash" ] || die "la clave descifrada no coincide con el hash esperado"
    if [ -f /restore/private.key ]; then
      if [ "$(sha256sum /restore/private.key | cut -c1-16)" = "$key_hash" ]; then
        echo "[restore] config/private.key ya es la correcta; no hay nada que hacer."
        exit 0
      fi
      bak="/restore/private.key.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      mv /restore/private.key "$bak"
      echo "[restore] la private.key anterior se guardó en ${bak#/restore/}"
    fi
    cp "$work/private.key" /restore/private.key
    chmod 600 /restore/private.key
    echo "[restore] config/private.key restaurada (hash ${key_hash})"
    ;;

  *)
    die "uso: restore.sh db|key <latest|NOMBRE>"
    ;;
esac
