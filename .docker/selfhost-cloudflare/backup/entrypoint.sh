#!/bin/sh
# Punto de entrada del contenedor de backups.
#
#   schedule          (por defecto) backup diario a la hora BACKUP_TIME (UTC, HH:MM)
#   backup            hace un backup ahora y termina
#   list              lista los backups guardados en R2
#   restore [clave]   restaura un dump (por defecto el más reciente) — ver restore.sh
set -eu

check_config() {
  missing=""
  for var in PGHOST PGUSER PGPASSWORD PGDATABASE BACKUP_BUCKET \
    RCLONE_CONFIG_R2_ENDPOINT RCLONE_CONFIG_R2_ACCESS_KEY_ID RCLONE_CONFIG_R2_SECRET_ACCESS_KEY; do
    eval "value=\${$var:-}"
    [ -n "$value" ] || missing="$missing $var"
  done
  if [ -n "$missing" ]; then
    echo "[backup] ERROR: faltan variables:$missing (revisa BACKUP_* y R2_ACCOUNT_ID en .env)" >&2
    exit 1
  fi
}

schedule() {
  BACKUP_TIME="${BACKUP_TIME:-07:00}"
  case "$BACKUP_TIME" in
    [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) ;;
    *)
      echo "[backup] ERROR: BACKUP_TIME debe tener formato HH:MM (UTC), valor actual: $BACKUP_TIME" >&2
      exit 1
      ;;
  esac
  echo "[backup] programado todos los días a las $BACKUP_TIME UTC -> r2:$BACKUP_BUCKET"
  while :; do
    now=$(date -u +%s)
    target=$(date -u -d "$(date -u +%Y-%m-%d) $BACKUP_TIME" +%s)
    if [ "$target" -le "$now" ]; then
      target=$((target + 86400))
    fi
    echo "[backup] próximo backup: $(date -u -d "@$target" '+%Y-%m-%d %H:%M UTC')"
    sleep $((target - now))
    if ! /usr/local/bin/backup.sh; then
      echo "[backup] ERROR: el backup falló; se reintentará en el próximo ciclo." >&2
    fi
  done
}

cmd="${1:-schedule}"
case "$cmd" in
  schedule)
    check_config
    schedule
    ;;
  backup)
    check_config
    exec /usr/local/bin/backup.sh
    ;;
  list)
    check_config
    exec rclone lsl "r2:${BACKUP_BUCKET}/"
    ;;
  restore)
    check_config
    shift
    exec /usr/local/bin/restore.sh "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
