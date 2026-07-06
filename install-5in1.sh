#!/usr/bin/env bash
#
# 在全新 Debian 12/13 VPS 上运行：
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-5in1.sh)
#
# 五个客户端节点：
#   1. VLESS + Reality，VPS原生出口
#   2. VLESS + Reality，Cloudflare WARP出口
#   3. Hysteria 2
#   4. VLESS + WebSocket + Cloudflare CDN
#   5. VLESS + WebSocket + Cloudflare Tunnel（Argo）
#
# 唯一代理内核为 Sing-box。Caddy、cloudflared 和官方 WARP 客户端只承担辅助职责。
# 脚本只面向空白服务器；发现已有部署或端口冲突时立即停止，不覆盖、不卸载。

set -Eeuo pipefail
umask 077

readonly SING_BOX_VERSION="1.13.14"
readonly CLOUDFLARED_VERSION="2026.6.1"
readonly SING_BOX_SHA256_AMD64="f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697"
readonly SING_BOX_SHA256_ARM64="4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e"
readonly CLOUDFLARED_SHA256_AMD64="5861a10a438fe8ddcfebb3b830f83966cbf193edafce0fe2eeb198fbae1f7a22"
readonly CLOUDFLARED_SHA256_ARM64="59816ce9b16db71f5bc2a86d59b3632a96c8c3ee934bde2bc8641ee83a6070eb"

readonly SING_BOX_CONFIG="/etc/sing-box/config.json"
readonly SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared-argo.service"
readonly ARGO_TOKEN_FILE="/etc/cloudflared/token"
readonly BBR_CONFIG="/etc/sysctl.d/99-bbr.conf"
readonly RESULT_FILE="/root/sing-box-client-info.txt"
readonly CLASH_PROFILE="/root/clash-verge.yaml"
readonly SUBSCRIPTION_DIR="/var/lib/caddy/subscriptions"

readonly REALITY_PORT="443"
readonly HY2_PORT="443"
readonly CDN_PORT="8443"
readonly CDN_WS_LOCAL_PORT="10000"
readonly ARGO_WS_LOCAL_PORT="10001"
readonly WARP_PROXY_PORT="40000"
readonly REALITY_TARGET="www.debian.org:443"
readonly REALITY_SERVER_NAME="www.debian.org"
readonly CERT_WAIT_SECONDS="180"

TEMP_DIR=""
STEP_NO=0
SERVER_IP=""
CDN_DOMAIN=""
HY2_DOMAIN=""
ARGO_DOMAIN=""
ARGO_TOKEN=""
ACME_EMAIL=""
ACME_ALT_PORT=""

if [[ -t 1 ]]; then
  readonly COLOR_GREEN=$'\033[1;32m'
  readonly COLOR_YELLOW=$'\033[1;33m'
  readonly COLOR_RED=$'\033[1;31m'
  readonly COLOR_CYAN=$'\033[1;36m'
  readonly COLOR_BOLD=$'\033[1m'
  readonly COLOR_RESET=$'\033[0m'
else
  readonly COLOR_GREEN=""
  readonly COLOR_YELLOW=""
  readonly COLOR_RED=""
  readonly COLOR_CYAN=""
  readonly COLOR_BOLD=""
  readonly COLOR_RESET=""
fi

say() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s[%s] %s%s\n' "${COLOR_CYAN}" "${STEP_NO}" "$1" "${COLOR_RESET}"
}

ok() {
  printf '%s完成：%s%s\n' "${COLOR_GREEN}" "$1" "${COLOR_RESET}"
}

warn() {
  printf '%s警告：%s%s\n' "${COLOR_YELLOW}" "$1" "${COLOR_RESET}" >&2
}

die() {
  printf '%s错误：%s%s\n' "${COLOR_RED}" "$1" "${COLOR_RESET}" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}

trap cleanup EXIT
trap 'die "第 ${STEP_NO} 步执行失败，请先处理上方第一条错误，不要反复运行脚本。"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行。"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "只支持 Debian 12/13。"
  [[ "${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13" ]] \
    || die "只支持 Debian 12/13，当前版本为 ${VERSION_ID:-未知}。"
  [[ "${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}" =~ ^(bookworm|trixie)$ ]] \
    || die "无法识别 Debian 软件源代号。"
}

port_is_listening() {
  local port="$1"
  ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

udp_port_is_listening() {
  local port="$1"
  ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

refuse_existing_installation() {
  say "检查已有部署和端口"

  command -v ss >/dev/null 2>&1 \
    || die "系统缺少端口检查工具 ss，无法安全确认端口是否空闲。"

  local command_name
  for command_name in xray sing-box hysteria caddy cloudflared warp-cli; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      die "检测到已有 ${command_name}。本脚本不会覆盖现有部署。"
    fi
  done

  local path
  for path in \
    /etc/sing-box \
    /usr/local/etc/xray \
    /etc/hysteria \
    /etc/caddy/Caddyfile \
    /etc/cloudflared \
    /var/lib/cloudflare-warp; do
    [[ ! -e "${path}" ]] || die "检测到已有路径 ${path}。本脚本不会覆盖。"
  done

  local service_name
  for service_name in sing-box.service xray.service hysteria-server.service caddy.service cloudflared.service cloudflared-argo.service warp-svc.service; do
    if systemctl list-unit-files "${service_name}" 2>/dev/null | grep -q "${service_name}"; then
      die "检测到已有服务 ${service_name}。本脚本不会覆盖。"
    fi
  done

  local tcp_port
  for tcp_port in 80 "${REALITY_PORT}" "${CDN_PORT}" "${CDN_WS_LOCAL_PORT}" "${ARGO_WS_LOCAL_PORT}" "${WARP_PROXY_PORT}"; do
    port_is_listening "${tcp_port}" && die "TCP端口 ${tcp_port} 已被占用。"
  done
  udp_port_is_listening "${HY2_PORT}" && die "UDP端口 ${HY2_PORT} 已被占用。"

  ok "未发现会被覆盖的部署或端口"
}

valid_domain() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

read_inputs() {
  printf '\n%sSing-box 五合一部署%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '准备三个Cloudflare子域名：\n'
  printf '  1. CDN域名：部署时灰云，证书成功后切橙云。\n'
  printf '  2. HY2域名：始终灰云。\n'
  printf '  3. Argo域名：已绑定固定Tunnel，服务地址设为 http://localhost:%s。\n' "${ARGO_WS_LOCAL_PORT}"

  read -r -p "CDN完整域名: " CDN_DOMAIN
  CDN_DOMAIN="${CDN_DOMAIN,,}"
  valid_domain "${CDN_DOMAIN}" || die "CDN域名格式不正确。"

  read -r -p "HY2完整域名: " HY2_DOMAIN
  HY2_DOMAIN="${HY2_DOMAIN,,}"
  valid_domain "${HY2_DOMAIN}" || die "HY2域名格式不正确。"

  read -r -p "Argo固定域名: " ARGO_DOMAIN
  ARGO_DOMAIN="${ARGO_DOMAIN,,}"
  valid_domain "${ARGO_DOMAIN}" || die "Argo域名格式不正确。"

  [[ "${CDN_DOMAIN}" != "${HY2_DOMAIN}" && "${CDN_DOMAIN}" != "${ARGO_DOMAIN}" && "${HY2_DOMAIN}" != "${ARGO_DOMAIN}" ]] \
    || die "三个用途必须使用不同子域名。"

  read -r -s -p "Argo Tunnel Token（输入时不会显示）: " ARGO_TOKEN
  printf '\n'
  [[ -n "${ARGO_TOKEN}" ]] || die "Argo Token不能为空。"
  [[ "${ARGO_TOKEN}" != *[[:space:]]* ]] || die "Argo Token不能包含空格或换行。"

  read -r -p "证书联系邮箱（可直接回车）: " ACME_EMAIL
  if [[ -n "${ACME_EMAIL}" && ! "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    die "邮箱格式不正确。"
  fi

  printf '\n即将部署：\n'
  printf '  Reality直连和WARP：TCP 443，目标 %s\n' "${REALITY_TARGET}"
  printf '  HY2：%s UDP 443\n' "${HY2_DOMAIN}"
  printf '  CDN：%s TCP 8443\n' "${CDN_DOMAIN}"
  printf '  Argo：%s → 本机 %s\n' "${ARGO_DOMAIN}" "${ARGO_WS_LOCAL_PORT}"
  read -r -p "确认DNS和Tunnel设置无误后输入 DEPLOY: " confirmation
  [[ "${confirmation}" == "DEPLOY" ]] || die "用户取消。"
}

install_base_packages() {
  say "安装基础工具"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl dnsutils gnupg jq lsb-release openssl tar iproute2
  ok "基础工具已安装"
}

enable_bbr() {
  say "启用BBR和fq"
  printf '%s\n' \
    'net.core.default_qdisc=fq' \
    'net.ipv4.tcp_congestion_control=bbr' \
    >"${BBR_CONFIG}"
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
    || die "BBR未能启用。"
  ok "BBR已启用"
}

detect_public_ip_and_dns() {
  say "核对公网IP和灰云DNS"
  SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  [[ "${SERVER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "无法取得VPS公网IPv4。"

  local domain
  for domain in "${CDN_DOMAIN}" "${HY2_DOMAIN}"; do
    mapfile -t domain_ips < <(
      dig +short A "${domain}" |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
        sort -u
    )
    [[ "${#domain_ips[@]}" -gt 0 ]] || die "${domain} 没有A记录。"
    printf '%s\n' "${domain_ips[@]}" | grep -Fxq "${SERVER_IP}" \
      || die "${domain} 未以灰云方式解析到当前VPS ${SERVER_IP}。"
  done
  ok "CDN和HY2域名均以灰云指向当前VPS"
}

architecture_values() {
  case "$(uname -m)" in
    x86_64)
      ARCH="amd64"
      SING_BOX_SHA256="${SING_BOX_SHA256_AMD64}"
      CLOUDFLARED_SHA256="${CLOUDFLARED_SHA256_AMD64}"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      SING_BOX_SHA256="${SING_BOX_SHA256_ARM64}"
      CLOUDFLARED_SHA256="${CLOUDFLARED_SHA256_ARM64}"
      ;;
    *) die "不支持CPU架构 $(uname -m)。" ;;
  esac
}

install_sing_box() {
  say "安装固定版本Sing-box"
  architecture_values
  local archive="sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${archive}"
  curl -fL --retry 2 "${url}" -o "${TEMP_DIR}/${archive}"
  printf '%s  %s\n' "${SING_BOX_SHA256}" "${TEMP_DIR}/${archive}" |
    sha256sum -c - >/dev/null
  tar -xzf "${TEMP_DIR}/${archive}" -C "${TEMP_DIR}"
  install -m 755 \
    "${TEMP_DIR}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" \
    /usr/local/bin/sing-box
  ok "Sing-box $(sing-box version | awk '/version/ {print $3; exit}') 已安装并校验"
}

install_caddy() {
  say "安装官方Caddy"
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
    gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
  ok "Caddy $(caddy version | head -n1) 已安装"
}

install_cloudflared() {
  say "安装固定版本cloudflared"
  architecture_values
  local url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}"
  curl -fL --retry 2 "${url}" -o "${TEMP_DIR}/cloudflared"
  printf '%s  %s\n' "${CLOUDFLARED_SHA256}" "${TEMP_DIR}/cloudflared" |
    sha256sum -c - >/dev/null
  install -m 755 "${TEMP_DIR}/cloudflared" "${CLOUDFLARED_BIN}"
  ok "cloudflared $(${CLOUDFLARED_BIN} --version | awk '{print $3}') 已安装并校验"
}

install_warp() {
  say "安装Cloudflare官方WARP客户端"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg |
    gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  chmod 644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  local codename
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"
  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "${codename}" \
    >/etc/apt/sources.list.d/cloudflare-client.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflare-warp

  systemctl enable --now warp-svc >/dev/null
  if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
    warp-cli --accept-tos registration new >/dev/null
  fi
  warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null
  warp-cli --accept-tos mode proxy >/dev/null
  warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}" >/dev/null
  warp-cli --accept-tos connect >/dev/null

  local elapsed=0
  while (( elapsed < 60 )); do
    if ss -H -ltn "sport = :${WARP_PROXY_PORT}" 2>/dev/null |
      grep -Eq '127\.0\.0\.1|\[::1\]'; then
      local trace
      trace="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace || true)"
      if grep -q '^warp=on$' <<<"${trace}"; then
        ok "WARP本地代理已监听127.0.0.1:${WARP_PROXY_PORT}，warp=on"
        return
      fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  die "WARP本地代理未在60秒内通过warp=on验证。"
}

generate_credentials() {
  say "生成独立凭证"
  REALITY_DIRECT_UUID="$(sing-box generate uuid)"
  REALITY_WARP_UUID="$(sing-box generate uuid)"
  CDN_UUID="$(sing-box generate uuid)"
  ARGO_UUID="$(sing-box generate uuid)"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  CDN_WS_PATH="/$(openssl rand -hex 12)"
  ARGO_WS_PATH="/$(openssl rand -hex 12)"
  SUBSCRIPTION_PATH="/$(openssl rand -hex 24).yaml"

  local key_output
  key_output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(awk -F': *' '/PrivateKey|Private key/ {print $2; exit}' <<<"${key_output}")"
  REALITY_PUBLIC_KEY="$(awk -F': *' '/PublicKey|Public key/ {print $2; exit}' <<<"${key_output}")"
  [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] \
    || die "无法解析Reality密钥。"

  ACME_ALT_PORT="$((20000 + RANDOM % 10000))"
  while port_is_listening "${ACME_ALT_PORT}"; do
    ACME_ALT_PORT="$((20000 + RANDOM % 10000))"
  done
  ok "五个节点的独立凭证已生成"
}

write_sing_box_config() {
  say "写入Sing-box配置"
  install -d -m 750 /etc/sing-box /var/lib/sing-box/acme
  cat >"${SING_BOX_CONFIG}" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "name": "reality-direct",
          "uuid": "${REALITY_DIRECT_UUID}",
          "flow": "xtls-rprx-vision"
        },
        {
          "name": "reality-warp",
          "uuid": "${REALITY_WARP_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${REALITY_SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "name": "hy2",
          "password": "${HY2_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${HY2_DOMAIN}",
        "acme": {
          "domain": [
            "${HY2_DOMAIN}"
          ],
          "data_directory": "/var/lib/sing-box/acme",
          "email": "${ACME_EMAIL}",
          "provider": "letsencrypt",
          "disable_tls_alpn_challenge": true,
          "alternative_http_port": ${ACME_ALT_PORT}
        }
      }
    },
    {
      "type": "vless",
      "tag": "cdn-ws",
      "listen": "127.0.0.1",
      "listen_port": ${CDN_WS_LOCAL_PORT},
      "users": [
        {
          "name": "cdn",
          "uuid": "${CDN_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${CDN_WS_PATH}"
      }
    },
    {
      "type": "vless",
      "tag": "argo-ws",
      "listen": "127.0.0.1",
      "listen_port": ${ARGO_WS_LOCAL_PORT},
      "users": [
        {
          "name": "argo",
          "uuid": "${ARGO_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${ARGO_WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": ${WARP_PROXY_PORT},
      "version": "5"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "auth_user": [
          "reality-warp"
        ],
        "action": "route",
        "outbound": "warp-out"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "action": "reject"
      }
    ],
    "final": "direct"
  }
}
EOF
  chmod 600 "${SING_BOX_CONFIG}"
  sing-box check -c "${SING_BOX_CONFIG}" || die "Sing-box配置检查失败。"
  ok "Sing-box配置检查通过"
}

write_sing_box_service() {
  cat >"${SING_BOX_SERVICE}" <<'EOF'
[Unit]
Description=Sing-box Five-in-One Proxy Core
After=network-online.target warp-svc.service caddy.service
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
  chmod 644 "${SING_BOX_SERVICE}"
}

write_clash_profile() {
  say "生成Clash/Mihomo五节点订阅"
  cat >"${CLASH_PROFILE}" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true

proxies:
  - name: VPS-Reality
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${REALITY_DIRECT_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SERVER_NAME}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}

  - name: VPS-Reality-WARP
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${REALITY_WARP_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SERVER_NAME}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}

  - name: VPS-HY2
    type: hysteria2
    server: ${HY2_DOMAIN}
    port: ${HY2_PORT}
    password: ${HY2_PASSWORD}
    sni: ${HY2_DOMAIN}
    alpn:
      - h3
    skip-cert-verify: false
    udp: true

  - name: VPS-CF-CDN
    type: vless
    server: ${CDN_DOMAIN}
    port: ${CDN_PORT}
    uuid: ${CDN_UUID}
    network: ws
    tls: true
    udp: true
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
    ws-opts:
      path: ${CDN_WS_PATH}
      headers:
        Host: ${CDN_DOMAIN}

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
    ws-opts:
      path: ${ARGO_WS_PATH}
      headers:
        Host: ${ARGO_DOMAIN}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - VPS-Reality
      - VPS-Reality-WARP
      - VPS-HY2
      - VPS-CF-CDN
      - VPS-Argo
      - DIRECT

rules:
  - MATCH,PROXY
EOF
  chmod 600 "${CLASH_PROFILE}"
  ok "五节点订阅已生成，CDN初始server使用自己的域名"
}

write_caddy_config() {
  say "写入Caddy配置"
  install -d -o root -g caddy -m 750 "${SUBSCRIPTION_DIR}"
  install -o root -g caddy -m 640 \
    "${CLASH_PROFILE}" "${SUBSCRIPTION_DIR}${SUBSCRIPTION_PATH}"

  {
    if [[ -n "${ACME_EMAIL}" ]]; then
      printf '{\n\temail %s\n}\n\n' "${ACME_EMAIL}"
    fi
    cat <<EOF
${CDN_DOMAIN}:${CDN_PORT} {
	@subscription path ${SUBSCRIPTION_PATH}
	handle @subscription {
		header Cache-Control "no-store"
		header Content-Type "text/yaml; charset=utf-8"
		root * ${SUBSCRIPTION_DIR}
		file_server
	}

	@cdn_websocket path ${CDN_WS_PATH}
	handle @cdn_websocket {
		reverse_proxy 127.0.0.1:${CDN_WS_LOCAL_PORT}
	}

	handle {
		respond 404
	}
}

http://${HY2_DOMAIN} {
	@hy2_acme path /.well-known/acme-challenge/*
	handle @hy2_acme {
		reverse_proxy 127.0.0.1:${ACME_ALT_PORT}
	}
	handle {
		respond 404
	}
}
EOF
  } >"${CADDY_CONFIG}"
  chown root:caddy "${CADDY_CONFIG}"
  chmod 640 "${CADDY_CONFIG}"
  caddy validate --config "${CADDY_CONFIG}" --adapter caddyfile \
    || die "Caddy配置检查失败。"
  ok "Caddy配置检查通过"
}

write_cloudflared_service() {
  say "配置Argo固定隧道"
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
ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file ${ARGO_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${CLOUDFLARED_SERVICE}"
  ok "Argo Token已写入受保护文件，未写入服务命令行"
}

configure_firewall() {
  say "检查防火墙"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow "${REALITY_PORT}/tcp" >/dev/null
    ufw allow "${CDN_PORT}/tcp" >/dev/null
    ufw allow "${HY2_PORT}/udp" >/dev/null
    ok "UFW已精确放行TCP 80/443/8443和UDP 443"
    return
  fi
  warn "未自动修改nftables或云防火墙；请确认TCP 80/443/8443和UDP 443已放行。"
}

start_services() {
  say "启动服务"
  systemctl daemon-reload
  systemctl enable --now caddy >/dev/null
  systemctl enable --now sing-box >/dev/null
  systemctl enable --now cloudflared-argo >/dev/null

  local service_name
  for service_name in caddy sing-box cloudflared-argo warp-svc; do
    if ! systemctl is-active --quiet "${service_name}"; then
      journalctl -u "${service_name}" -n 80 --no-pager >&2 || true
      die "服务 ${service_name} 启动失败。"
    fi
  done
  ok "Sing-box、Caddy、cloudflared和WARP均已运行并开机自启"
}

verify_websocket() {
  local url="$1"
  local host="$2"
  local resolve_value="${3:-}"
  local args=(
    -sS --http1.1 --max-time 12
    -H 'Connection: Upgrade'
    -H 'Upgrade: websocket'
    -H 'Sec-WebSocket-Version: 13'
    -H 'Sec-WebSocket-Key: SGVsbG9Xb3JsZDEyMzQ1Ng=='
    -H "Host: ${host}"
    -o /dev/null -w '%{http_code}'
  )
  if [[ -n "${resolve_value}" ]]; then
    args+=(--resolve "${resolve_value}")
  fi
  curl "${args[@]}" "${url}" 2>/dev/null || true
}

verify_runtime() {
  say "验证五条路线的服务端链路"
  port_is_listening "${REALITY_PORT}" || die "Reality没有监听TCP 443。"
  udp_port_is_listening "${HY2_PORT}" || die "HY2没有监听UDP 443。"
  port_is_listening "${CDN_PORT}" || die "Caddy没有监听TCP 8443。"
  ss -H -ltn "sport = :${CDN_WS_LOCAL_PORT}" | grep -q '127.0.0.1' \
    || die "CDN WebSocket未仅监听127.0.0.1。"
  ss -H -ltn "sport = :${ARGO_WS_LOCAL_PORT}" | grep -q '127.0.0.1' \
    || die "Argo WebSocket未仅监听127.0.0.1。"

  printf '等待CDN和HY2证书，最长%s秒' "${CERT_WAIT_SECONDS}"
  local elapsed=0
  local cdn_ready=false
  while (( elapsed < CERT_WAIT_SECONDS )); do
    if curl -sS --max-time 8 \
      --resolve "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1" \
      "https://${CDN_DOMAIN}:${CDN_PORT}/" -o /dev/null 2>/dev/null; then
      cdn_ready=true
      break
    fi
    printf '.'
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf '\n'
  [[ "${cdn_ready}" == true ]] || die "CDN证书未在限定时间内就绪。"

  local cdn_code
  cdn_code="$(verify_websocket \
    "https://${CDN_DOMAIN}:${CDN_PORT}${CDN_WS_PATH}" \
    "${CDN_DOMAIN}" \
    "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1")"
  [[ "${cdn_code}" == "101" ]] || die "CDN WebSocket未返回HTTP 101（实际${cdn_code:-无响应}）。"

  local argo_code
  argo_code="$(verify_websocket \
    "https://${ARGO_DOMAIN}${ARGO_WS_PATH}" \
    "${ARGO_DOMAIN}")"
  [[ "${argo_code}" == "101" ]] || die "Argo WebSocket未返回HTTP 101（实际${argo_code:-无响应}）。请核对Tunnel公共主机名的服务地址。"

  local downloaded_profile="${TEMP_DIR}/downloaded-profile.yaml"
  curl -fsS --max-time 10 \
    --resolve "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1" \
    "https://${CDN_DOMAIN}:${CDN_PORT}${SUBSCRIPTION_PATH}" \
    -o "${downloaded_profile}"
  cmp -s "${CLASH_PROFILE}" "${downloaded_profile}" \
    || die "HTTPS订阅内容与本地配置不一致。"

  local warp_trace
  warp_trace="$(curl -fsS --max-time 12 --socks5-hostname "127.0.0.1:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace)"
  grep -q '^warp=on$' <<<"${warp_trace}" || die "WARP出口没有返回warp=on。"
  ok "Reality监听、HY2监听、CDN HTTP 101、Argo HTTP 101、订阅一致性和WARP出口均通过"
}

write_client_info() {
  say "保存客户端信息"
  local encoded_cdn_path encoded_argo_path subscription_url
  encoded_cdn_path="%2F${CDN_WS_PATH#/}"
  encoded_argo_path="%2F${ARGO_WS_PATH#/}"
  subscription_url="https://${CDN_DOMAIN}:${CDN_PORT}${SUBSCRIPTION_PATH}"

  local reality_link reality_warp_link hy2_link cdn_link argo_link
  reality_link="vless://${REALITY_DIRECT_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VPS-Reality"
  reality_warp_link="vless://${REALITY_WARP_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VPS-Reality-WARP"
  hy2_link="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&alpn=h3&insecure=0#VPS-HY2"
  cdn_link="vless://${CDN_UUID}@${CDN_DOMAIN}:${CDN_PORT}?encryption=none&security=tls&sni=${CDN_DOMAIN}&type=ws&host=${CDN_DOMAIN}&path=${encoded_cdn_path}#VPS-CF-CDN"
  argo_link="vless://${ARGO_UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=${encoded_argo_path}#VPS-Argo"

  cat >"${RESULT_FILE}" <<EOF
Sing-box五合一客户端信息
生成时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')

【Reality直连】
${reality_link}

【Reality-WARP】
${reality_warp_link}

【Hysteria 2】
${hy2_link}

【Cloudflare CDN】
${cdn_link}

【Argo固定隧道】
${argo_link}

【Clash Verge / Mihomo统一订阅】
${subscription_url}

部署后的CDN优选：只把客户端或订阅中的CDN节点server改为本地测速所得优选IP/域名。
servername和WebSocket Host必须继续使用${CDN_DOMAIN}。

重要：本文件、节点链接、订阅地址和Argo Token均为秘密，不要公开。
EOF
  chmod 600 "${RESULT_FILE}"

  printf '\n%s部署与服务端验证完成。%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
  printf '客户端信息：%s\n' "${RESULT_FILE}"
  printf 'Clash订阅：%s\n' "${subscription_url}"
  printf '下一步：把%s切换为橙云并设置“完全（严格）”，然后从实际客户端逐个测试五个节点。\n' "${CDN_DOMAIN}"
  printf 'HY2域名%s必须始终保持灰云。\n' "${HY2_DOMAIN}"
}

finish_after_warp_install() {
  generate_credentials
  write_sing_box_config
  write_sing_box_service
  write_clash_profile
  write_caddy_config
  write_cloudflared_service
  configure_firewall
  start_services
  verify_runtime
  write_client_info
}

resume_after_warp_failure() {
  require_root
  require_debian

  command -v sing-box >/dev/null 2>&1 \
    && command -v caddy >/dev/null 2>&1 \
    && command -v cloudflared >/dev/null 2>&1 \
    || die "续跑条件不满足：前七步并未完整安装。"
  [[ ! -f "${SING_BOX_CONFIG}" && ! -f "${CLOUDFLARED_SERVICE}" ]] \
    || die "检测到五合一配置或服务已经生成，不能使用第8步专用续跑模式。"

  read_inputs
  TEMP_DIR="$(mktemp -d)"
  detect_public_ip_and_dns
  install_warp
  finish_after_warp_install
}

main() {
  if [[ "${1:-}" == "--resume-after-warp" ]]; then
    resume_after_warp_failure
    return
  fi
  [[ $# -eq 0 ]] || die "未知参数：${1}"

  require_root
  require_debian
  refuse_existing_installation
  read_inputs
  TEMP_DIR="$(mktemp -d)"

  install_base_packages
  enable_bbr
  detect_public_ip_and_dns
  install_sing_box
  install_caddy
  install_cloudflared
  install_warp
  finish_after_warp_install
}

main "$@"
