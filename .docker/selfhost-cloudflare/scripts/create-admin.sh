#!/usr/bin/env sh
# Crea el primer administrador de AFFiNE DESDE EL PROPIO SERVIDOR, antes de
# publicar el Tunnel. Así el endpoint público /api/setup/create-admin-user
# (que no pide autenticación hasta que existe el primer usuario) nunca queda
# expuesto a Internet.
#
# Uso:
#   ./scripts/create-admin.sh correo@dominio.com "Nombre Apellido"
#
# La contraseña se pide por teclado (o se toma de la variable ADMIN_PASSWORD).
set -eu

cd "$(dirname "$0")/.."

ADMIN_EMAIL="${1:-${ADMIN_EMAIL:-}}"
ADMIN_NAME="${2:-${ADMIN_NAME:-}}"

if [ -z "$ADMIN_EMAIL" ]; then
  printf 'Correo del administrador: '
  IFS= read -r ADMIN_EMAIL
fi

if [ -z "${ADMIN_PASSWORD:-}" ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: define ADMIN_PASSWORD o ejecuta el script en una terminal interactiva." >&2
    exit 1
  fi
  stty -echo
  trap 'stty echo' EXIT INT TERM
  printf 'Contraseña (8 a 32 caracteres): '
  IFS= read -r ADMIN_PASSWORD
  printf '\nRepite la contraseña: '
  IFS= read -r ADMIN_PASSWORD_CONFIRM
  printf '\n'
  stty echo
  trap - EXIT INT TERM
  if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo "ERROR: las contraseñas no coinciden." >&2
    exit 1
  fi
fi

export ADMIN_EMAIL ADMIN_NAME ADMIN_PASSWORD

if ! docker compose ps --status running --services | grep -qx affine; then
  echo "ERROR: el servicio 'affine' no está corriendo. Ejecuta primero: docker compose up -d affine" >&2
  exit 1
fi

echo "Esperando a que AFFiNE responda en http://127.0.0.1:3010/info ..."
i=0
until docker compose exec -T affine node -e \
  "fetch('http://127.0.0.1:3010/info').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" \
  >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "ERROR: AFFiNE no respondió en 5 minutos. Revisa: docker compose logs affine" >&2
    exit 1
  fi
  sleep 5
done

docker compose exec -T -e ADMIN_EMAIL -e ADMIN_NAME -e ADMIN_PASSWORD affine \
  node --input-type=module -e '
const body = {
  email: process.env.ADMIN_EMAIL,
  password: process.env.ADMIN_PASSWORD,
};
if (process.env.ADMIN_NAME) body.name = process.env.ADMIN_NAME;
const res = await fetch("http://127.0.0.1:3010/api/setup/create-admin-user", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});
const text = await res.text();
if (!res.ok) {
  let message = text;
  try {
    const json = JSON.parse(text);
    message = json.message || json.name || text;
  } catch {}
  console.error(`ERROR (${res.status}): ${message}`);
  process.exit(1);
}
console.log(`Administrador creado: ${body.email}`);
'

echo "Listo. Ahora publica el Tunnel con: docker compose up -d"
