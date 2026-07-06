#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install-4in1.sh"

grep -Fq "printf '\\thttps_port %s\\n}\\n\\n' \"\${HY2_CERT_LOCAL_PORT}\"" "${script}"
grep -Fq 'cat <<EOF' "${script}"
grep -Fq '${HY2_DOMAIN} {' "${script}"
if grep -Fq 'https://${HY2_DOMAIN}:${HY2_CERT_LOCAL_PORT} {' "${script}"; then
  echo 'HY2域名仍直接携带内部端口，Caddy不会按标准域名触发自动HTTPS。' >&2
  exit 1
fi

echo 'Caddy HY2内部HTTPS端口配置正确。'
