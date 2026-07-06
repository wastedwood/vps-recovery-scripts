#!/usr/bin/env bash
#
# Fresh Debian 12/13 installer:
#   bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-4in1.sh)
#
# Nodes: Reality direct, Reality via WARP, Hysteria 2, and VLESS WebSocket via Argo.
# Sing-box is the only proxy core. It owns HY2 ACME and the WARP WireGuard endpoint.

set -Eeuo pipefail
umask 077

readonly SING_BOX_VERSION="1.13.14"
readonly CLOUDFLARED_VERSION="2026.6.1"
readonly WGCF_VERSION="2.2.31"
readonly SING_BOX_SHA256_AMD64="f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697"
readonly SING_BOX_SHA256_ARM64="4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e"
readonly CLOUDFLARED_SHA256_AMD64="5861a10a438fe8ddcfebb3b830f83966cbf193edafce0fe2eeb198fbae1f7a22"
readonly CLOUDFLARED_SHA256_ARM64="59816ce9b16db71f5bc2a86d59b3632a96c8c3ee934bde2bc8641ee83a6070eb"
readonly WGCF_SHA256_AMD64="69147e1a517c66129edd8ac8cb60484d6c9515178d7b4a2f95e3c925f225572a"
readonly WGCF_SHA256_ARM64="b9bdbdeaa3f9f4ba741ba55b8bd94c24f7166c27668eb7e8192ccf9746961182"

readonly SING_BOX_CONFIG="/etc/sing-box/config.json"
readonly SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared-argo.service"
readonly ARGO_TOKEN_FILE="/etc/cloudflared/token"
readonly BBR_CONFIG="/etc/sysctl.d/99-bbr.conf"
readonly RESULT_FILE="/root/sing-box-client-info.txt"
readonly CLASH_PROFILE="/root/clash-verge.yaml"

readonly REALITY_PORT="443"
readonly HY2_PORT="443"
readonly ARGO_WS_LOCAL_PORT="10001"
readonly WARP_TEST_PORT="40000"
readonly REALITY_TARGET="www.debian.org:443"
readonly REALITY_SERVER_NAME="www.debian.org"
readonly CERT_WAIT_SECONDS="180"
readonly ROUTE_WAIT_SECONDS="60"

TEMP_DIR=""
STEP_NO=0
SERVER_IP=""
HY2_DOMAIN=""
ARGO_DOMAIN=""
ARGO_TOKEN=""
ACME_EMAIL=""
ARCH=""
SING_BOX_SHA256=""
CLOUDFLARED_SHA256=""
WGCF_SHA256=""
WARP_PRIVATE_KEY=""
WARP_IPV4=""
WARP_IPV6=""
WARP_PEER_PUBLIC_KEY=""
WARP_ENDPOINT_HOST=""
WARP_ENDPOINT_PORT=""

if [[ -t 1 ]]; then
  readonly GREEN=$'\033[1;32m' YELLOW=$'\033[1;33m' RED=$'\033[1;31m'
  readonly CYAN=$'\033[1;36m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  readonly GREEN="" YELLOW="" RED="" CYAN="" BOLD="" RESET=""
fi

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}

on_error() {
  local exit_code=$?
  printf '\n错误：脚本在第 %s 行停止，退出码 %s。\n' "${1:-unknown}" "${exit_code}" >&2
  printf '请保留上方第一条错误信息，不要直接重复运行。\n' >&2
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

say() { STEP_NO=$((STEP_NO + 1)); printf '\n%s[步骤 %s] %s%s\n' "${CYAN}" "${STEP_NO}" "$1" "${RESET}"; }
ok() { printf '%s✓ %s%s\n' "${GREEN}" "$1" "${RESET}"; }
warn() { printf '%s! %s%s\n' "${YELLOW}" "$1" "${RESET}" >&2; }
die() { printf '\n%s错误：%s%s\n' "${RED}" "$1" "${RESET}" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行。"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "无法读取系统版本。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "目前只支持 Debian 12/13。"
  case "${VERSION_ID:-}" in 12|13) ;; *) die "检测到 Debian ${VERSION_ID:-未知版本}，仅支持12/13。" ;; esac
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

port_is_listening() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"; }
udp_port_is_listening() { ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"; }

refuse_existing_installation() {
  say "检查服务器是否为空白环境"
  command -v ss >/dev/null 2>&1 || die "系统缺少 ss，无法检查端口。"
  local command_name
  for command_name in xray sing-box hysteria cloudflared; do
    command -v "${command_name}" >/dev/null 2>&1 && die "检测到已有 ${command_name}，不会覆盖。"
  done
  local path
  for path in /etc/sing-box /usr/local/etc/xray /etc/hysteria /etc/cloudflared; do
    [[ ! -e "${path}" ]] || die "检测到已有路径 ${path}，不会覆盖。"
  done
  local service_name
  for service_name in sing-box.service xray.service hysteria-server.service cloudflared.service cloudflared-argo.service; do
    systemctl list-unit-files "${service_name}" 2>/dev/null | grep -q "${service_name}" \
      && die "检测到已有服务 ${service_name}，不会覆盖。"
  done
  port_is_listening 80 && die "TCP 80 已被占用，Sing-box无法完成HY2证书验证。"
  port_is_listening "${REALITY_PORT}" && die "TCP 443 已被占用。"
  port_is_listening "${ARGO_WS_LOCAL_PORT}" && die "TCP ${ARGO_WS_LOCAL_PORT} 已被占用。"
  port_is_listening "${WARP_TEST_PORT}" && die "TCP ${WARP_TEST_PORT} 已被占用。"
  udp_port_is_listening "${HY2_PORT}" && die "UDP 443 已被占用。"
  ok "未发现冲突"
}

read_inputs() {
  printf '\n%sSing-box 四合一部署%s\n' "${BOLD}" "${RESET}"
  printf '要求：TCP 80/443、UDP 443已放行；HY2域名保持灰云。\n'
  printf '固定Tunnel的服务地址必须设置为 http://localhost:%s。\n\n' "${ARGO_WS_LOCAL_PORT}"

  read -r -p "HY2完整域名（例如 hy2.example.com）: " HY2_DOMAIN
  HY2_DOMAIN="${HY2_DOMAIN,,}"
  valid_domain "${HY2_DOMAIN}" || die "HY2域名格式不正确。"

  read -r -p "Argo完整域名（例如 argo.example.com）: " ARGO_DOMAIN
  ARGO_DOMAIN="${ARGO_DOMAIN,,}"
  valid_domain "${ARGO_DOMAIN}" || die "Argo域名格式不正确。"
  [[ "${ARGO_DOMAIN}" != "${HY2_DOMAIN}" ]] || die "HY2和Argo必须使用不同域名。"

  read -r -s -p "固定Tunnel Token（输入时不显示）: " ARGO_TOKEN
  printf '\n'
  [[ -n "${ARGO_TOKEN}" ]] || die "Tunnel Token不能为空。"

  read -r -p "ACME邮箱（可直接回车跳过）: " ACME_EMAIL
  if [[ -n "${ACME_EMAIL}" && ! "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    die "邮箱格式不正确。"
  fi

  read -r -p "确认设置无误后输入 DEPLOY: " confirmation
  [[ "${confirmation}" == "DEPLOY" ]] || die "用户取消。"
}

install_base_packages() {
  say "安装基础工具"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl dnsutils jq openssl tar iproute2
  ok "基础工具已安装"
}

enable_bbr() {
  say "启用BBR和fq"
  cat >"${BBR_CONFIG}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR未成功启用。"
  ok "BBR和fq已启用"
}

detect_public_ip_and_dns() {
  say "核对公网IPv4和DNS"
  SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org)" || die "无法获取公网IPv4。"
  [[ "${SERVER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "公网IPv4格式异常。"
  local hy2_ip
  hy2_ip="$(dig +short A "${HY2_DOMAIN}" | tail -n1)"
  [[ "${hy2_ip}" == "${SERVER_IP}" ]] \
    || die "${HY2_DOMAIN} 当前解析为 ${hy2_ip:-无记录}，应为 ${SERVER_IP}，并保持灰云。"
  ok "HY2域名正确解析到 ${SERVER_IP}"
}

architecture_values() {
  case "$(uname -m)" in
    x86_64|amd64)
      ARCH="amd64"; SING_BOX_SHA256="${SING_BOX_SHA256_AMD64}"
      CLOUDFLARED_SHA256="${CLOUDFLARED_SHA256_AMD64}"; WGCF_SHA256="${WGCF_SHA256_AMD64}"
      ;;
    aarch64|arm64)
      ARCH="arm64"; SING_BOX_SHA256="${SING_BOX_SHA256_ARM64}"
      CLOUDFLARED_SHA256="${CLOUDFLARED_SHA256_ARM64}"; WGCF_SHA256="${WGCF_SHA256_ARM64}"
      ;;
    *) die "不支持CPU架构 $(uname -m)。" ;;
  esac
}

install_sing_box() {
  say "安装固定版本Sing-box"
  architecture_values
  local archive="sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
  curl -fL --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${archive}" \
    -o "${TEMP_DIR}/${archive}"
  printf '%s  %s\n' "${SING_BOX_SHA256}" "${TEMP_DIR}/${archive}" | sha256sum -c - >/dev/null
  tar -xzf "${TEMP_DIR}/${archive}" -C "${TEMP_DIR}"
  install -m 755 "${TEMP_DIR}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box
  sing-box version | grep -q 'with_acme' || die "Sing-box构建不含ACME功能。"
  sing-box version | grep -q 'with_wireguard' || die "Sing-box构建不含WireGuard功能。"
  ok "Sing-box ${SING_BOX_VERSION} 已安装并校验"
}

install_cloudflared() {
  say "安装固定版本cloudflared"
  local url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}"
  curl -fL --retry 2 "${url}" -o "${TEMP_DIR}/cloudflared"
  printf '%s  %s\n' "${CLOUDFLARED_SHA256}" "${TEMP_DIR}/cloudflared" | sha256sum -c - >/dev/null
  install -m 755 "${TEMP_DIR}/cloudflared" "${CLOUDFLARED_BIN}"
  ok "cloudflared ${CLOUDFLARED_VERSION} 已安装并校验"
}

generate_warp_profile() {
  say "生成Sing-box内置WARP凭据"
  local wgcf="${TEMP_DIR}/wgcf"
  local profile="${TEMP_DIR}/wgcf-profile.conf"
  curl -fL --retry 2 \
    "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH}" \
    -o "${wgcf}"
  printf '%s  %s\n' "${WGCF_SHA256}" "${wgcf}" | sha256sum -c - >/dev/null
  chmod 700 "${wgcf}"
  (
    cd "${TEMP_DIR}"
    "${wgcf}" register --accept-tos >/dev/null
    "${wgcf}" generate >/dev/null
  )

  WARP_PRIVATE_KEY="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "${profile}" | head -n1)"
  local addresses endpoint
  addresses="$(awk -F' *= *' '/^Address/ {print $2; exit}' "${profile}")"
  WARP_IPV4="$(tr ',' '\n' <<<"${addresses}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 '\.')"
  WARP_IPV6="$(tr ',' '\n' <<<"${addresses}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -m1 ':')"
  WARP_PEER_PUBLIC_KEY="$(sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' "${profile}" | head -n1)"
  endpoint="$(awk -F' *= *' '/^Endpoint/ {print $2; exit}' "${profile}")"
  WARP_ENDPOINT_HOST="${endpoint%:*}"
  WARP_ENDPOINT_PORT="${endpoint##*:}"
  WARP_ENDPOINT_HOST="${WARP_ENDPOINT_HOST#[}"
  WARP_ENDPOINT_HOST="${WARP_ENDPOINT_HOST%]}"

  [[ -n "${WARP_PRIVATE_KEY}" && -n "${WARP_IPV4}" && -n "${WARP_IPV6}" \
    && -n "${WARP_PEER_PUBLIC_KEY}" && -n "${WARP_ENDPOINT_HOST}" \
    && "${WARP_ENDPOINT_PORT}" =~ ^[0-9]+$ ]] || die "无法完整解析WARP WireGuard凭据。"
  ok "WARP凭据已生成；临时注册文件将在脚本退出时清理"
}

generate_credentials() {
  say "生成节点凭证"
  REALITY_DIRECT_UUID="$(sing-box generate uuid)"
  REALITY_WARP_UUID="$(sing-box generate uuid)"
  ARGO_UUID="$(sing-box generate uuid)"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  ARGO_WS_PATH="/$(openssl rand -hex 12)"
  local key_output
  key_output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk -F': *' '/PrivateKey|Private key/ {print $2; exit}' <<<"${key_output}")"
  REALITY_PUBLIC_KEY="$(awk -F': *' '/PublicKey|Public key/ {print $2; exit}' <<<"${key_output}")"
  [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || die "无法解析Reality密钥。"
  ok "节点凭证已生成"
}

write_sing_box_config() {
  say "写入Sing-box配置"
  install -d -m 700 /etc/sing-box /var/lib/sing-box/acme
  cat >"${SING_BOX_CONFIG}" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "mtu": 1280,
      "address": ["${WARP_IPV4}", "${WARP_IPV6}"],
      "private_key": "${WARP_PRIVATE_KEY}",
      "peers": [
        {
          "address": "${WARP_ENDPOINT_HOST}",
          "port": ${WARP_ENDPOINT_PORT},
          "public_key": "${WARP_PEER_PUBLIC_KEY}",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 30
        }
      ]
    }
  ],
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": ${REALITY_PORT},
      "users": [
        { "name": "reality-direct", "uuid": "${REALITY_DIRECT_UUID}", "flow": "xtls-rprx-vision" },
        { "name": "reality-warp", "uuid": "${REALITY_WARP_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true, "server_name": "${REALITY_SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SERVER_NAME}", "server_port": 443 },
          "private_key": "${REALITY_PRIVATE_KEY}", "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${HY2_PORT},
      "users": [{ "name": "hy2", "password": "${HY2_PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "acme": {
          "domain": ["${HY2_DOMAIN}"],
          "data_directory": "/var/lib/sing-box/acme",
          "email": "${ACME_EMAIL}",
          "provider": "letsencrypt",
          "disable_http_challenge": false,
          "disable_tls_alpn_challenge": true
        }
      }
    },
    {
      "type": "vless", "tag": "argo-ws", "listen": "127.0.0.1", "listen_port": ${ARGO_WS_LOCAL_PORT},
      "users": [{ "name": "argo", "uuid": "${ARGO_UUID}" }],
      "transport": { "type": "ws", "path": "${ARGO_WS_PATH}" }
    },
    {
      "type": "mixed", "tag": "warp-test", "listen": "127.0.0.1", "listen_port": ${WARP_TEST_PORT}
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "inbound": ["warp-test"], "action": "route", "outbound": "warp-out" },
      { "auth_user": ["reality-warp"], "action": "route", "outbound": "warp-out" },
      { "protocol": ["bittorrent"], "action": "reject" }
    ],
    "final": "direct"
  }
}
EOF
  chmod 600 "${SING_BOX_CONFIG}"
  sing-box check -c "${SING_BOX_CONFIG}" || die "Sing-box配置检查失败。"
  ok "Sing-box配置检查通过"
}

write_services() {
  say "写入系统服务"
  cat >"${SING_BOX_SERVICE}" <<'EOF'
[Unit]
Description=Sing-box Four-in-One Proxy Core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  install -d -m 700 /etc/cloudflared
  printf '%s' "${ARGO_TOKEN}" >"${ARGO_TOKEN_FILE}"
  chmod 600 "${ARGO_TOKEN_FILE}"
  ARGO_TOKEN=""
  cat >"${CLOUDFLARED_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for Sing-box Argo Node
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --url http://127.0.0.1:${ARGO_WS_LOCAL_PORT} run --token-file ${ARGO_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${SING_BOX_SERVICE}" "${CLOUDFLARED_SERVICE}"
  ok "系统服务已写入"
}

write_client_files() {
  say "生成客户端文件"
  local encoded_path="%2F${ARGO_WS_PATH#/}"
  REALITY_LINK="vless://${REALITY_DIRECT_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VPS-Reality"
  REALITY_WARP_LINK="vless://${REALITY_WARP_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VPS-Reality-WARP"
  HY2_LINK="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&alpn=h3&insecure=0#VPS-HY2"
  ARGO_LINK="vless://${ARGO_UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${encoded_path}#VPS-Argo"

  cat >"${CLASH_PROFILE}" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
proxies:
  - { name: VPS-Reality, type: vless, server: ${SERVER_IP}, port: 443, uuid: ${REALITY_DIRECT_UUID}, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: ${REALITY_SERVER_NAME}, client-fingerprint: chrome, reality-opts: { public-key: ${REALITY_PUBLIC_KEY}, short-id: ${REALITY_SHORT_ID} } }
  - { name: VPS-Reality-WARP, type: vless, server: ${SERVER_IP}, port: 443, uuid: ${REALITY_WARP_UUID}, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: ${REALITY_SERVER_NAME}, client-fingerprint: chrome, reality-opts: { public-key: ${REALITY_PUBLIC_KEY}, short-id: ${REALITY_SHORT_ID} } }
  - { name: VPS-HY2, type: hysteria2, server: ${HY2_DOMAIN}, port: 443, password: ${HY2_PASSWORD}, sni: ${HY2_DOMAIN}, alpn: [h3], skip-cert-verify: false, udp: true }
  - name: VPS-Argo
    type: vless
    server: ${ARGO_DOMAIN}
    port: 443
    uuid: ${ARGO_UUID}
    network: ws
    tls: true
    udp: true
    servername: ${ARGO_DOMAIN}
    client-fingerprint: chrome
    ws-opts: { path: "${ARGO_WS_PATH}", headers: { Host: ${ARGO_DOMAIN} } }
proxy-groups:
  - { name: PROXY, type: select, proxies: [VPS-Reality, VPS-Reality-WARP, VPS-HY2, VPS-Argo, DIRECT] }
rules:
  - MATCH,PROXY
EOF

  cat >"${RESULT_FILE}" <<EOF
Sing-box四合一客户端信息
生成时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')

【Reality直连】
${REALITY_LINK}

【Reality-WARP】
${REALITY_WARP_LINK}

【Hysteria 2】
${HY2_LINK}

【Argo固定隧道】
${ARGO_LINK}

【Clash Verge / Mihomo本地配置】
${CLASH_PROFILE}

以上内容均为秘密，不要公开。
EOF
  chmod 600 "${CLASH_PROFILE}" "${RESULT_FILE}"
  ok "客户端文件已生成"
}

configure_firewall() {
  say "检查防火墙"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    ok "UFW已放行TCP 80/443和UDP 443"
  else
    warn "未修改云防火墙或nftables；请确认TCP 80/443和UDP 443已放行。"
  fi
}

wait_for_certificate() {
  printf '等待Sing-box签发HY2证书，最长%s秒' "${CERT_WAIT_SECONDS}"
  local elapsed=0
  while (( elapsed < CERT_WAIT_SECONDS )); do
    if journalctl -u sing-box --since "${CERT_WAIT_SECONDS} seconds ago" --no-pager 2>/dev/null \
      | grep -q 'certificate obtained successfully'; then
      printf '\n'; ok "HY2证书已签发"; return
    fi
    systemctl is-active --quiet sing-box || break
    printf '.'; sleep 5; elapsed=$((elapsed + 5))
  done
  printf '\n'; journalctl -u sing-box -n 100 --no-pager >&2 || true
  die "Sing-box未在限定时间内签发HY2证书。请检查TCP 80和HY2灰云DNS。"
}

wait_for_routes() {
  printf '等待WARP和Argo链路就绪，最长%s秒' "${ROUTE_WAIT_SECONDS}"
  local elapsed=0 trace="" argo_code=""
  local warp_ready=false argo_ready=false
  while (( elapsed < ROUTE_WAIT_SECONDS )); do
    if [[ "${warp_ready}" == false ]]; then
      trace="$(curl -fsS --max-time 8 --socks5-hostname "127.0.0.1:${WARP_TEST_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
      grep -q '^warp=on$' <<<"${trace}" && warp_ready=true
    fi
    if [[ "${argo_ready}" == false ]]; then
      argo_code="$(curl -sS --http1.1 --max-time 8 -o /dev/null -w '%{http_code}' \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: SGVsbG9Xb3JsZDEyMzQ1Ng==' \
        "https://${ARGO_DOMAIN}${ARGO_WS_PATH}" 2>/dev/null || true)"
      [[ "${argo_code}" == "101" ]] && argo_ready=true
    fi
    if [[ "${warp_ready}" == true && "${argo_ready}" == true ]]; then
      printf '\n'; ok "WARP和Argo链路已就绪"; return
    fi
    printf '.'; sleep 3; elapsed=$((elapsed + 3))
  done
  printf '\n'
  [[ "${warp_ready}" == true ]] || die "Sing-box内置WARP出口未返回warp=on。"
  die "Argo WebSocket未返回HTTP 101（实际${argo_code:-无响应}）。请将Tunnel服务地址设为http://localhost:${ARGO_WS_LOCAL_PORT}。"
}

start_and_verify() {
  say "启动并验证服务"
  systemctl daemon-reload
  systemctl enable --now sing-box >/dev/null
  wait_for_certificate
  systemctl enable --now cloudflared-argo >/dev/null
  systemctl is-active --quiet sing-box || die "Sing-box启动失败。"
  systemctl is-active --quiet cloudflared-argo || die "cloudflared启动失败。"
  port_is_listening "${REALITY_PORT}" || die "Reality没有监听TCP 443。"
  udp_port_is_listening "${HY2_PORT}" || die "HY2没有监听UDP 443。"
  ss -H -ltn "sport = :${ARGO_WS_LOCAL_PORT}" | grep -q '127.0.0.1' || die "Argo入口未监听本机端口。"
  wait_for_routes
  ok "Reality、HY2、Argo和Sing-box内置WARP均通过验证"
}

finish_deployment() {
  write_sing_box_config
  write_services
  write_client_files
  configure_firewall
  start_and_verify
  printf '\n%s部署完成。%s\n客户端信息：%s\nClash配置：%s\n' \
    "${GREEN}" "${RESET}" "${RESULT_FILE}" "${CLASH_PROFILE}"
}

resume_after_config_failure() {
  require_root
  require_debian
  command -v sing-box >/dev/null 2>&1 && command -v cloudflared >/dev/null 2>&1 \
    || die "续跑条件不满足：Sing-box或cloudflared尚未完整安装。"
  [[ -f "${SING_BOX_CONFIG}" && ! -f "${SING_BOX_SERVICE}" \
    && ! -f "${CLOUDFLARED_SERVICE}" ]] \
    || die "当前状态不属于第9步配置检查失败，拒绝续跑。"

  read_inputs
  TEMP_DIR="$(mktemp -d)"
  architecture_values
  detect_public_ip_and_dns
  generate_warp_profile
  generate_credentials
  finish_deployment
}

main() {
  if [[ "${1:-}" == "--resume-after-config-failure" ]]; then
    resume_after_config_failure
    return
  fi
  [[ $# -eq 0 ]] || die "不支持参数：${1}"
  require_root
  require_debian
  refuse_existing_installation
  read_inputs
  TEMP_DIR="$(mktemp -d)"
  install_base_packages
  enable_bbr
  detect_public_ip_and_dns
  install_sing_box
  install_cloudflared
  generate_warp_profile
  generate_credentials
  finish_deployment
}

main "$@"
