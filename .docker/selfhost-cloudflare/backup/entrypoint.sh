#!/bin/sh
# Punto de entrada del contenedor de backups.
#
#   schedule                   (por defecto) backup diario a la hora BACKUP_TIME (UTC, HH:MM)
#   backup                     hace un backup ahora y termina
#   list                       lista los backups guardados en R2
#   restore <latest|CLAVE>     restaura un dump en Postgres (ver restore.sh)
#   restore-key <latest|CLAVE> recupera la private.key que corresponde a ese dump
#   keygen                     genera el par de claves age para cifrar los backups
set -eu

HEARTBEAT=/tmp/backup-heartbeat
IDENTITY_FILE="${BACKUP_AGE_IDENTITY_FILE:-/run/secrets/age-identity}"

die() {
  echo "[backup] ERROR: $*" >&2
  exit 1
}

require_vars() {
  missing=""
  for var in "$@"; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || missing="$missing $var"
  done
  [ -z "$missing" ] || die "faltan variables:$missing (revisa .env)"
}

# Construye el endpoint S3 de R2 a partir de la cuenta y la jurisdicción,
# salvo que BACKUP_R2_ENDPOINT lo fije explícitamente.
setup_rclone() {
  require_vars BACKUP_BUCKET BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY
  if [ -z "${BACKUP_R2_ENDPOINT:-}" ]; then
    require_vars R2_ACCOUNT_ID
    case "${R2_JURISDICTION:-default}" in
      eu) BACKUP_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com" ;;
      default) BACKUP_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" ;;
      *) die "R2_JURISDICTION debe ser default o eu" ;;
    esac
  fi
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER="${BACKUP_RCLONE_PROVIDER:-Cloudflare}"
  export RCLONE_CONFIG_R2_ENDPOINT="$BACKUP_R2_ENDPOINT"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$BACKUP_R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$BACKUP_R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

require_postgres() {
  require_vars PGHOST PGUSER PGPASSWORD PGDATABASE
}

require_recipient() {
  require_vars BACKUP_AGE_RECIPIENT
  case "$BACKUP_AGE_RECIPIENT" in
    age1*) ;;
    *) die "BACKUP_AGE_RECIPIENT debe ser una clave pública age (empieza por age1…). Genera una con: docker compose run --rm --no-deps backup keygen" ;;
  esac
}

require_identity() {
  [ -s "$IDENTITY_FILE" ] || die "no encuentro la clave privada age en $IDENTITY_FILE. Móntala con: -v /ruta/a/age-identity.txt:$IDENTITY_FILE:ro"
}

# Comprueba al arrancar que Postgres y el bucket responden, para que un fallo
# de credenciales se vea en el momento y no a la hora del primer backup.
preflight() {
  pg_isready -q -t 10 || die "Postgres no responde en ${PGHOST}"
  rclone lsf --max-depth 1 "r2:${BACKUP_BUCKET}/" >/dev/null ||
    die "no puedo listar r2:${BACKUP_BUCKET} (revisa BACKUP_R2_* y R2_ACCOUNT_ID)"
}

schedule() {
  BACKUP_TIME="${BACKUP_TIME:-07:00}"
  case "$BACKUP_TIME" in
    [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) ;;
    *) die "BACKUP_TIME debe tener formato HH:MM (UTC), valor actual: $BACKUP_TIME" ;;
  esac
  preflight
  # Latido para el healthcheck: se renueva con cada backup correcto.
  date -u +%s >"$HEARTBEAT"
  echo "[backup] programado todos los días a las $BACKUP_TIME UTC -> r2:$BACKUP_BUCKET"
  while :; do
    now=$(date -u +%s)
    target=$(date -u -d "$(date -u +%Y-%m-%d) $BACKUP_TIME" +%s)
    if [ "$target" -le "$now" ]; then
      target=$((target + 86400))
    fi
    echo "[backup] próximo backup: $(date -u -d "@$target" '+%Y-%m-%d %H:%M UTC')"
    sleep $((target - now))
    if /usr/local/bin/backup.sh; then
      date -u +%s >"$HEARTBEAT"
    else
      echo "[backup] ERROR: el backup falló; se reintentará en el próximo ciclo." >&2
    fi
  done
}

cmd="${1:-schedule}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
  schedule)
    require_postgres
    require_recipient
    setup_rclone
    schedule
    ;;
  backup)
    require_postgres
    require_recipient
    setup_rclone
    exec /usr/local/bin/backup.sh
    ;;
  list)
    setup_rclone
    echo "== dumps de Postgres (postgres/)"
    rclone lsl "r2:${BACKUP_BUCKET}/postgres/" | sort -k 4
    echo "== claves privadas de AFFiNE (keys/)"
    rclone lsl "r2:${BACKUP_BUCKET}/keys/" | sort -k 4
    ;;
  restore)
    require_postgres
    require_identity
    setup_rclone
    exec /usr/local/bin/restore.sh db "$@"
    ;;
  restore-key)
    require_identity
    setup_rclone
    exec /usr/local/bin/restore.sh key "$@"
    ;;
  keygen)
    tmpdir=$(mktemp -d)
    age-keygen -o "$tmpdir/key" 2>/dev/null || die "age-keygen falló"
    pub=$(age-keygen -y "$tmpdir/key")
    echo "=== CLAVE PRIVADA (guárdala FUERA del servidor, p. ej. en tu gestor de contraseñas) ==="
    cat "$tmpdir/key"
    rm -rf "$tmpdir"
    echo
    echo "=== Pon esta línea en .env ==="
    echo "BACKUP_AGE_RECIPIENT=$pub"
    ;;
  healthcheck)
    [ -s "$HEARTBEAT" ] || exit 1
    elapsed=$(($(date -u +%s) - $(cat "$HEARTBEAT")))
    # Sano si el último backup correcto (o el arranque) fue hace menos de 26 h.
    [ "$elapsed" -lt 93600 ]
    ;;
  *)
    exec "$cmd" "$@"
    ;;
esac
