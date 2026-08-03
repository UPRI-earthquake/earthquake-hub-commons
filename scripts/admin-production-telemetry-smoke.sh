#!/usr/bin/env bash
set -euo pipefail

compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:-${compose_dir}/.env}"
compose=(docker compose --profile admin --env-file "${env_file}" -f "${compose_dir}/docker-compose.yml")

"${compose[@]}" config --quiet
"${compose[@]}" ps admin-backend ehub-backend

if [[ -n "$(docker port admin-backend 5100/tcp 2>/dev/null || true)" ]]; then
  echo "ERROR: admin-backend port 5100 must not be published to the host." >&2
  exit 1
fi

members="$(docker network inspect earthquake-hub-admin-telemetry-network \
  --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | sort)"
unexpected="$(printf '%s\n' "${members}" | sed '/^$/d' | grep -Ev '^(admin-backend|ehub-backend)$' || true)"
if [[ -n "${unexpected}" ]]; then
  echo "ERROR: unexpected container(s) attached to the admin telemetry network:" >&2
  echo "${unexpected}" >&2
  exit 1
fi
for required in admin-backend ehub-backend; do
  if ! printf '%s\n' "${members}" | grep -Fxq "${required}"; then
    echo "ERROR: ${required} is not attached to the admin telemetry network." >&2
    exit 1
  fi
done

"${compose[@]}" exec -T admin-backend wget -q -O - http://127.0.0.1:5101/health
echo

"${compose[@]}" exec -T ehub-backend node <<'NODE'
const fs = require('fs');
const https = require('https');

const resources = ['deployment', 'seiscomp', 'archive', 'system', 'wstunnel'];
const tls = {
  hostname: 'admin-backend',
  port: 5100,
  ca: fs.readFileSync('/run/secrets/admin-telemetry/ca.crt'),
  cert: fs.readFileSync('/run/secrets/admin-telemetry/tls.crt'),
  key: fs.readFileSync('/run/secrets/admin-telemetry/tls.key'),
  headers: {
    Accept: 'application/json',
    Authorization: `Bearer ${process.env.ADMIN_HOST_TELEMETRY_TOKEN || ''}`,
  },
  minVersion: 'TLSv1.2',
  rejectUnauthorized: true,
};

function read(resource) {
  return new Promise((resolve, reject) => {
    const request = https.get({ ...tls, path: `/v1/${resource}` }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        try {
          const payload = JSON.parse(body);
          if (response.statusCode !== 200 || payload.source !== 'admin-backend') {
            throw new Error(`${resource}: unexpected HTTP ${response.statusCode}`);
          }
          console.log(`${resource}: ${payload.status}${payload.errorCode ? ` (${payload.errorCode})` : ''}`);
          resolve();
        } catch (error) {
          reject(error);
        }
      });
    });
    request.setTimeout(5000, () => request.destroy(new Error(`${resource}: timeout`)));
    request.on('error', reject);
  });
}

Promise.all(resources.map(read)).catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
NODE

echo "Admin telemetry transport, network membership, and fixed resources verified."
