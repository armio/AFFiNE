#!/usr/bin/env node
// Genera ~/.affine/config/config.json a partir de variables de entorno (.env).
//
// Lo ejecuta el servicio `affine_config` de compose.yml antes de las migraciones,
// así que .env es la única fuente de verdad: si cambias .env, vuelve a correr
// `docker compose up -d` y el archivo se regenera.
//
// Notas importantes (verificadas contra AFFiNE 0.27.x):
// - Las claves de almacenamiento DEBEN ir "planas con punto": storages["blob.storage"],
//   storages["avatar.storage"] y copilot.storage. Un objeto anidado se ignora en
//   silencio y AFFiNE vuelve a guardar en disco local.
// - Con usePresignedURL.enabled + signKey, el navegador sube los archivos a AFFiNE
//   (/api/storage/upload y /api/storage/multipart, en partes de 5 MiB) y es AFFiNE
//   quien escribe en R2. No hace falta CORS en el bucket y ninguna petición normal
//   supera el límite de 100 MB del proxy de Cloudflare.
// - Lo que se cambie en el panel /admin se guarda en Postgres y tiene prioridad
//   sobre este archivo.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CONFIG_DIR =
  process.env.AFFINE_CONFIG_DIR || path.join(os.homedir(), '.affine', 'config');
const OUT_FILE = path.join(CONFIG_DIR, 'config.json');

const errors = [];
const warnings = [];

function read(name, fallback) {
  const value = process.env[name];
  if (value === undefined) return fallback;
  const trimmed = value.trim();
  return trimmed === '' ? fallback : trimmed;
}

function required(name, hint) {
  const value = read(name);
  if (value === undefined) {
    errors.push(`Falta ${name}${hint ? ` (${hint})` : ''}`);
  }
  return value;
}

function bool(name, fallback) {
  const value = read(name);
  if (value === undefined) return fallback;
  if (/^(1|true|yes|on|si|sí)$/i.test(value)) return true;
  if (/^(0|false|no|off)$/i.test(value)) return false;
  errors.push(`${name} debe ser true o false (valor actual: "${value}")`);
  return fallback;
}

function int(name, fallback) {
  const value = read(name);
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || String(parsed) !== value) {
    errors.push(`${name} debe ser un número entero (valor actual: "${value}")`);
    return fallback;
  }
  return parsed;
}

// --- Servidor ---------------------------------------------------------------
const rawDomain = required('AFFINE_DOMAIN', 'por ejemplo affine.ddoblee.com');
const domain = rawDomain
  ?.replace(/^https?:\/\//i, '')
  .replace(/\/+$/, '')
  .toLowerCase();
if (domain && !/^[a-z0-9.-]+(:\d+)?$/.test(domain)) {
  errors.push(
    `AFFINE_DOMAIN debe ser solo el hostname, sin ruta (valor actual: "${rawDomain}")`
  );
}

const config = {
  $schema:
    'https://github.com/toeverything/affine/releases/latest/download/config.schema.json',
  deployment: { type: 'selfhosted' },
  server: {
    name: read('AFFINE_SERVER_NAME', 'AFFiNE'),
    externalUrl: `https://${domain}`,
    host: domain,
    https: true,
  },
  auth: {
    allowSignup: bool('AFFINE_ALLOW_SIGNUP', false),
  },
  indexer: {
    enabled: true,
    'provider.type': 'embedded',
  },
  copilot: {
    enabled: bool('AFFINE_COPILOT_ENABLED', false),
  },
};

// --- Almacenamiento ---------------------------------------------------------
const storageMode = read('AFFINE_STORAGE', 'r2').toLowerCase();
let storageSummary = 'disco local (./data/storage)';

if (storageMode === 'r2') {
  const accountId = required('R2_ACCOUNT_ID', 'ID de tu cuenta de Cloudflare');
  const accessKeyId = required('R2_ACCESS_KEY_ID', 'token S3 de R2');
  const secretAccessKey = required('R2_SECRET_ACCESS_KEY', 'token S3 de R2');
  const signKey = required(
    'AFFINE_UPLOAD_SIGN_KEY',
    'genera uno con: openssl rand -hex 32'
  );
  const jurisdiction = read('R2_JURISDICTION', 'default');
  if (!['default', 'eu'].includes(jurisdiction)) {
    errors.push(
      `R2_JURISDICTION debe ser "default" o "eu" (valor actual: "${jurisdiction}")`
    );
  }
  if (accountId && !/^[0-9a-f]{32}$/i.test(accountId)) {
    warnings.push(
      'R2_ACCOUNT_ID no parece un ID de cuenta de Cloudflare (32 caracteres hexadecimales).'
    );
  }
  if (signKey && signKey.length < 32) {
    errors.push('AFFINE_UPLOAD_SIGN_KEY debe tener al menos 32 caracteres.');
  }

  const buckets = {
    blobs: read('R2_BUCKET_BLOBS', 'affine-blobs'),
    avatars: read('R2_BUCKET_AVATARS', 'affine-avatars'),
    copilot: read('R2_BUCKET_COPILOT', 'affine-copilot'),
  };

  const r2 = () => ({
    accountId,
    jurisdiction,
    credentials: { accessKeyId, secretAccessKey },
  });

  config.storages = {
    'blob.storage': {
      provider: 'cloudflare-r2',
      bucket: buckets.blobs,
      config: {
        ...r2(),
        usePresignedURL: { enabled: true, signKey },
      },
    },
    'avatar.storage': {
      provider: 'cloudflare-r2',
      bucket: buckets.avatars,
      config: r2(),
    },
  };
  config.copilot.storage = {
    provider: 'cloudflare-r2',
    bucket: buckets.copilot,
    config: r2(),
  };
  storageSummary = `Cloudflare R2 (blobs=${buckets.blobs}, avatars=${buckets.avatars}, copilot=${buckets.copilot}, subidas vía servidor)`;
} else if (storageMode === 'local') {
  warnings.push(
    'AFFINE_STORAGE=local: los archivos se guardan en ./data/storage del host, no en R2.'
  );
} else {
  errors.push(
    `AFFINE_STORAGE debe ser "r2" o "local" (valor actual: "${storageMode}")`
  );
}

// --- Correo (SMTP) ----------------------------------------------------------
const mailerHost = read('MAILER_HOST');
let mailerSummary = 'sin configurar (no se enviarán invitaciones ni enlaces mágicos)';
if (mailerHost) {
  const sender = required(
    'MAILER_SENDER',
    'por ejemplo "AFFiNE <affine@tudominio.com>"'
  );
  const port = int('MAILER_PORT', 465);
  config.mailer = {
    'SMTP.host': mailerHost,
    'SMTP.port': port,
    'SMTP.username': read('MAILER_USER', ''),
    'SMTP.password': read('MAILER_PASSWORD', ''),
    'SMTP.sender': sender,
    'SMTP.ignoreTLS': false,
  };
  if (!read('MAILER_PASSWORD')) {
    warnings.push('MAILER_PASSWORD está vacío: el servidor SMTP rechazará los envíos.');
  }
  mailerSummary = `${mailerHost}:${port}`;
} else {
  warnings.push(
    'MAILER_HOST está vacío: AFFiNE no podrá enviar invitaciones, enlaces mágicos ni restablecer contraseñas.'
  );
}

// --- Resultado --------------------------------------------------------------
for (const warning of warnings) console.warn(`[render-config] AVISO: ${warning}`);

if (errors.length) {
  for (const error of errors) console.error(`[render-config] ERROR: ${error}`);
  console.error(
    '[render-config] No se generó config.json. Corrige .env y vuelve a ejecutar `docker compose up -d`.'
  );
  process.exit(1);
}

fs.mkdirSync(CONFIG_DIR, { recursive: true });
const tmpFile = `${OUT_FILE}.tmp-${process.pid}`;
fs.writeFileSync(tmpFile, `${JSON.stringify(config, null, 2)}\n`, {
  mode: 0o600,
});
fs.renameSync(tmpFile, OUT_FILE);
fs.chmodSync(OUT_FILE, 0o600);

// config/ guarda secretos (credenciales de R2/SMTP y private.key): solo root.
try {
  fs.chmodSync(CONFIG_DIR, 0o700);
  const privateKey = path.join(CONFIG_DIR, 'private.key');
  if (fs.existsSync(privateKey)) fs.chmodSync(privateKey, 0o600);
} catch (error) {
  console.warn(
    `[render-config] AVISO: no se pudieron ajustar permisos en ${CONFIG_DIR}: ${error.message}`
  );
}

console.log(`[render-config] ${OUT_FILE} generado`);
console.log(`[render-config]   URL pública:   https://${domain}`);
console.log(`[render-config]   Archivos:      ${storageSummary}`);
console.log(`[render-config]   Correo:        ${mailerSummary}`);
console.log(
  `[render-config]   Registro libre: ${config.auth.allowSignup ? 'sí' : 'no (el admin crea las cuentas)'}`
);
console.log(
  `[render-config]   Copilot (IA):  ${config.copilot.enabled ? 'activado' : 'desactivado'}`
);
