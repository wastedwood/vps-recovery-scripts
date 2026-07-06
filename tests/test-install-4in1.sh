#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install-4in1.sh"

grep -Fq 'readonly WGCF_VERSION="2.2.31"' "${script}"
grep -Fq '"type": "wireguard"' "${script}"
grep -Fq '"tag": "warp-out"' "${script}"
grep -Fq '"acme": {' "${script}"
grep -Fq '"disable_tls_alpn_challenge": true' "${script}"
grep -Fq -- '--url http://127.0.0.1:${ARGO_WS_LOCAL_PORT}' "${script}"
grep -Fq "sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p'" "${script}"
grep -Fq "sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p'" "${script}"
grep -Fq -- '--resume-after-config-failure' "${script}"

for forbidden in install_caddy warp-cli warp-svc pkg.cloudflareclient.com WARP_PROXY_PORT; do
  if grep -Fq "${forbidden}" "${script}"; then
    echo "发现已废弃组件引用：${forbidden}" >&2
    exit 1
  fi
done

echo 'Sing-box内置ACME和WARP架构检查通过。'
