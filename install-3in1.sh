#!/usr/bin/env bash
#
# 推荐用法（登录全新 VPS 后，直接运行一行命令）：
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-3in1.sh)
#
# 备用用法（从 Windows 手动上传本脚本）：
#
# 1. 将下面命令中的 <服务器IP> 替换为新 VPS 的公网 IPv4。
#
# 2. 从 Windows 上传本脚本：
#    scp "<本地路径>\scripts\install-3in1.sh" root@<服务器IP>:/root/
#
# 3. SSH 登录新 VPS：
#    ssh root@<服务器IP>
#
# 4. 登录 VPS 后，授权并运行脚本：
#    chmod +x /root/install-3in1.sh
#    /root/install-3in1.sh
#
# 注意：
# - 只能在全新的 Debian 12/13 VPS 上运行。
# - 运行前先在 Cloudflare 创建指向该 VPS 的灰云 A 记录。
# - 如果执行中报错，不要反复运行，先处理第一条错误信息。
#
# 在全新的 Debian 12/13 VPS 上部署：
#   1. VLESS + REALITY，TCP 443
#   2. Hysteria 2，UDP 443
#   3. VLESS + WebSocket，经 Caddy/Cloudflare，TCP 8443
#   4. Clash Verge 随机 HTTPS 订阅
#   5. BBR 拥塞控制和 fq 队列
#
# 设计原则：
# - 仅面向空白服务器，不覆盖 3x-ui 或已有 sing-box/Xray/Caddy 部署。
# - 使用固定版本的 sing-box 和 Caddy 官方 Debian 软件源。
# - 自动生成新的 UUID、REALITY 密钥、Short ID 和 WebSocket 路径。
# - 不创建网页面板、数据库或流量统计；订阅文件由本机 Caddy 自托管。
#
# 状态：sing-box替换已完成静态检查，尚未在真实VPS完整实测。
# 最后审查：2026-07-07

set -Eeuo pipefail
umask 077

readonly SING_BOX_VERSION="1.13.14"
readonly SING_BOX_SHA256_AMD64="f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697"
readonly SING_BOX_SHA256_ARM64="4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e"
readonly HYSTERIA_INSTALL_URL="https://raw.githubusercontent.com/apernet/hysteria/master/scripts/install_server.sh"
readonly SING_BOX_CONFIG="/etc/sing-box/config.json"
readonly SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
readonly LEGACY_XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
readonly HYSTERIA_SERVICE="hysteria-server.service"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly BBR_CONFIG="/etc/sysctl.d/99-bbr.conf"
readonly RESULT_FILE="/root/sing-box-client-info.txt"
readonly CLASH_PROFILE="/root/clash-verge.yaml"
readonly SUBSCRIPTION_DIR="/var/lib/caddy/subscriptions"
readonly WS_LOCAL_PORT="10000"
readonly REALITY_PORT="443"
readonly HY2_PORT="443"
readonly CDN_PORT="8443"
readonly CERT_WAIT_SECONDS="120"

TEMP_DIR=""
STEP_NO=0
CDN_TLS_READY=false
ARCH=""
SING_BOX_SHA256=""

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

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  printf '\n%s  ✗ 脚本异常中止%s\n' "${COLOR_RED}" "${COLOR_RESET}" >&2
  printf '    位置：第 %s 行；退出码：%s\n' "${line_no}" "${exit_code}" >&2
  printf '    请先查看上方第一条错误信息，不要反复执行脚本。\n' >&2
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

say() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s━━ [步骤 %02d] %s ━━%s\n' \
    "${COLOR_CYAN}" "${STEP_NO}" "$1" "${COLOR_RESET}"
}

input_title() {
  printf '\n%s── [输入 %s/5] %s%s\n' \
    "${COLOR_CYAN}" "$1" "$2" "${COLOR_RESET}"
}

ok() {
  printf '%s  ✓ %s%s\n' "${COLOR_GREEN}" "$1" "${COLOR_RESET}"
}

warn() {
  printf '%s  ! %s%s\n' "${COLOR_YELLOW}" "$1" "${COLOR_RESET}" >&2
}

die() {
  printf '\n%s  ✗ 错误：%s%s\n' "${COLOR_RED}" "$1" "${COLOR_RESET}" >&2
  exit 1
}

wait_status() {
  printf '  %s…%s 正在等待 %s' "${COLOR_CYAN}" "${COLOR_RESET}" "$1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行。"
}

require_debian() {
  [[ -r /etc/os-release ]] || die "无法读取系统版本。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "本脚本目前只支持 Debian 12/13。"
  case "${VERSION_ID:-}" in
    12|13) ;;
    *) die "检测到 Debian ${VERSION_ID:-未知版本}，仅允许 Debian 12/13。" ;;
  esac
}

port_is_listening() {
  local port=$1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

udp_port_is_listening() {
  local port=$1
  ss -lunH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

refuse_existing_installation() {
  if command -v x-ui >/dev/null 2>&1 || [[ -d /usr/local/x-ui ]]; then
    die "检测到 3x-ui/x-ui。本脚本不会覆盖现有面板，请换空白 VPS 测试。"
  fi

  if command -v sing-box >/dev/null 2>&1 ||
    [[ -e "${SING_BOX_CONFIG}" ]] ||
    [[ -e "${SING_BOX_SERVICE}" ]]; then
    die "检测到已有 sing-box。本脚本不会覆盖现有配置。"
  fi

  if command -v xray >/dev/null 2>&1 || [[ -e "${LEGACY_XRAY_CONFIG}" ]]; then
    die "检测到已有 Xray。为避免服务或端口冲突，请换空白 VPS 测试。"
  fi

  if command -v caddy >/dev/null 2>&1 || [[ -e "${CADDY_CONFIG}" ]]; then
    die "检测到已有 Caddy。本脚本不会覆盖现有配置。"
  fi

  if command -v hysteria >/dev/null 2>&1 ||
    [[ -e "${HYSTERIA_CONFIG}" ]] ||
    systemctl list-unit-files "${HYSTERIA_SERVICE}" 2>/dev/null | grep -q "${HYSTERIA_SERVICE}"; then
    die "检测到已有 Hysteria。本脚本不会覆盖现有配置。"
  fi

  for port in 80 "${REALITY_PORT}" "${CDN_PORT}" "${WS_LOCAL_PORT}"; do
    if port_is_listening "${port}"; then
      die "端口 ${port} 已被占用。本脚本不会自动停止现有服务。"
    fi
  done

  if udp_port_is_listening "${HY2_PORT}"; then
    die "UDP ${HY2_PORT} 已被占用。本脚本不会自动停止现有服务。"
  fi
}

read_inputs() {
  printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' \
    "${COLOR_CYAN}" "${COLOR_RESET}"
  printf '%s              VPS 三节点部署向导%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' \
    "${COLOR_CYAN}" "${COLOR_RESET}"
  printf '完成后将得到三个独立节点和一条 Clash Verge 订阅：\n'
  printf '  1. Reality：主节点，部署后立即测试\n'
  printf '  2. Hysteria 2：UDP弱网备用节点\n'
  printf '  3. Cloudflare CDN：切换橙云后使用的备用节点\n\n'
  printf '%s运行要求：%s全新的 Debian 12/13 VPS；开放 TCP 22、80、443、8443 和 UDP 443。\n\n' \
    "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '%sCloudflare DNS必须提前创建两条A记录：%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '\n【CDN子域名】\n'
  printf '  记录类型：A\n'
  printf '  名称：例如 cdn.example.com（前缀 cdn + 根域名 example.com）\n'
  printf '  IPv4 地址：填写这台新 VPS 的公网 IPv4\n'
  printf '  代理状态：关闭代理，保持灰云（仅 DNS）\n'
  printf '  TTL：自动\n'
  printf '  部署完成后再切换橙云\n\n'
  printf '【HY2子域名】\n'
  printf '  记录类型：A\n'
  printf '  名称：例如 hy2.example.com（前缀 hy2 + 根域名 example.com）\n'
  printf '  IPv4 地址：填写同一台VPS的公网IPv4\n'
  printf '  代理状态：始终保持灰云（仅DNS），不能开启橙云\n'
  printf '  TTL：自动\n\n'
  printf '脚本会核对两个域名；不符合条件时会停止。\n\n'

  input_title 1 "根域名"
  printf '只填写共同的根域名，例如 example.com。不要填写 cdn 或 hy2 前缀。\n'
  read -r -p "请输入: " ROOT_DOMAIN
  ROOT_DOMAIN="${ROOT_DOMAIN,,}"
  [[ "${ROOT_DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
    || die "根域名格式不正确。请填写类似 example.com 的域名。"

  input_title 2 "CDN 前缀"
  printf '直接按回车使用默认前缀 cdn。\n'
  read -r -p "请输入（可直接回车）: " CDN_PREFIX
  CDN_PREFIX="${CDN_PREFIX,,}"
  CDN_PREFIX="${CDN_PREFIX:-cdn}"
  [[ "${CDN_PREFIX}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "CDN 前缀格式不正确，只能使用字母、数字和中划线。"
  CDN_DOMAIN="${CDN_PREFIX}.${ROOT_DOMAIN}"
  (( ${#CDN_DOMAIN} <= 253 )) || die "CDN 完整域名超过 253 个字符。"
  ok "CDN 完整域名：${CDN_DOMAIN}"

  input_title 3 "HY2 前缀"
  printf '直接按回车使用默认前缀 hy2；该域名必须始终保持灰云。\n'
  read -r -p "请输入（可直接回车）: " HY2_PREFIX
  HY2_PREFIX="${HY2_PREFIX,,}"
  HY2_PREFIX="${HY2_PREFIX:-hy2}"
  [[ "${HY2_PREFIX}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "HY2 前缀格式不正确，只能使用字母、数字和中划线。"
  [[ "${HY2_PREFIX}" != "${CDN_PREFIX}" ]] \
    || die "CDN 与 HY2 必须使用两个不同的前缀。"
  HY2_DOMAIN="${HY2_PREFIX}.${ROOT_DOMAIN}"
  (( ${#HY2_DOMAIN} <= 253 )) || die "HY2 完整域名超过 253 个字符。"
  ok "HY2 完整域名：${HY2_DOMAIN}"

  input_title 4 "Reality 目标"
  printf '不了解这项就直接按回车，使用默认值 www.debian.org:443。\n'
  read -r -p "请输入（可直接回车）: " REALITY_TARGET
  REALITY_TARGET="${REALITY_TARGET:-www.debian.org:443}"
  [[ "${REALITY_TARGET}" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] \
    || die "REALITY 目标必须是 域名:端口。"

  REALITY_SERVER_NAME="${REALITY_TARGET%:*}"
  REALITY_TARGET_PORT="${REALITY_TARGET##*:}"
  (( REALITY_TARGET_PORT >= 1 && REALITY_TARGET_PORT <= 65535 )) \
    || die "REALITY 目标端口超出范围。"

  input_title 5 "证书联系邮箱"
  printf '这项可留空，直接按回车即可。\n'
  read -r -p "请输入（可直接回车）: " ACME_EMAIL
  if [[ -n "${ACME_EMAIL}" && ! "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    die "邮箱格式不正确。"
  fi

  printf '\n%s── 部署确认 ──%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '  Reality  VPS_IP:%s；伪装目标 %s\n' "${REALITY_PORT}" "${REALITY_TARGET}"
  printf '  HY2      %s:%s/UDP；始终灰云\n' "${HY2_DOMAIN}" "${HY2_PORT}"
  printf '  CDN      %s:%s；转发到 127.0.0.1:%s\n' \
    "${CDN_DOMAIN}" "${CDN_PORT}" "${WS_LOCAL_PORT}"
  printf '\n继续前请再次确认：两个A记录均为灰云，并已指向这台VPS。\n'
  read -r -p "确认无误后输入 DEPLOY 并回车: " CONFIRM
  [[ "${CONFIRM}" == "DEPLOY" ]] || die "用户取消。"
}

install_base_packages() {
  say "安装基础工具"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates coreutils curl debian-archive-keyring debian-keyring \
    dnsutils gnupg iproute2 kmod openssl tar
  ok "基础工具安装完成"
}

enable_bbr() {
  say "启用 BBR 网络优化"

  if ! modprobe tcp_bbr 2>/dev/null; then
    die "当前系统内核无法加载 tcp_bbr，未继续部署。"
  fi

  cat >"${BBR_CONFIG}" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl -p "${BBR_CONFIG}" >"${TEMP_DIR}/sysctl.log" 2>&1 || {
    cat "${TEMP_DIR}/sysctl.log" >&2
    die "应用 BBR 系统配置失败。"
  }

  local congestion_control
  local queue_discipline
  congestion_control="$(sysctl -n net.ipv4.tcp_congestion_control)"
  queue_discipline="$(sysctl -n net.core.default_qdisc)"

  [[ "${congestion_control}" == "bbr" ]] \
    || die "BBR 验证失败，当前拥塞控制为 ${congestion_control}。"
  [[ "${queue_discipline}" == "fq" ]] \
    || die "fq 验证失败，当前队列规则为 ${queue_discipline}。"
  sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw 'bbr' \
    || die "BBR 验证失败，内核可用算法中没有 bbr。"

  ok "BBR 已启用并持久化：tcp_congestion_control=bbr，default_qdisc=fq"
}

detect_public_ip() {
  say "检查公网 IP 和 DNS"

  SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  [[ "${SERVER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "无法自动取得 VPS 公网 IPv4。"

  local domain
  for domain in "${CDN_DOMAIN}" "${HY2_DOMAIN}"; do
    mapfile -t DOMAIN_IPS < <(
      dig +short A "${domain}" |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' |
        sort -u
    )

    [[ "${#DOMAIN_IPS[@]}" -gt 0 ]] \
      || die "${domain} 暂时没有 A 记录，请先在 Cloudflare 添加灰云记录。"

    local matched=false
    local ip
    for ip in "${DOMAIN_IPS[@]}"; do
      if [[ "${ip}" == "${SERVER_IP}" ]]; then
        matched=true
        break
      fi
    done

    if [[ "${matched}" != true ]]; then
      printf '当前 VPS IP：%s\n' "${SERVER_IP}" >&2
      printf '%s 解析结果：%s\n' "${domain}" "${DOMAIN_IPS[*]}" >&2
      die "${domain} 未直接解析到当前 VPS。请保持灰云并等待DNS生效。"
    fi

    ok "${domain} 已以灰云方式解析到当前 VPS"
  done
}

install_sing_box() {
  say "安装固定版本 sing-box"

  case "$(uname -m)" in
    x86_64|amd64)
      ARCH="amd64"
      SING_BOX_SHA256="${SING_BOX_SHA256_AMD64}"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      SING_BOX_SHA256="${SING_BOX_SHA256_ARM64}"
      ;;
    *)
      die "不支持CPU架构 $(uname -m)，仅支持 amd64 和 arm64。"
      ;;
  esac

  local archive="sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"
  local download_url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${archive}"

  curl -fL --retry 2 --retry-delay 2 "${download_url}" -o "${TEMP_DIR}/${archive}"
  printf '%s  %s\n' "${SING_BOX_SHA256}" "${TEMP_DIR}/${archive}" |
    sha256sum -c - >/dev/null || die "sing-box 安装包校验失败。"
  tar -xzf "${TEMP_DIR}/${archive}" -C "${TEMP_DIR}"
  install -m 755 \
    "${TEMP_DIR}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" \
    /usr/local/bin/sing-box

  command -v sing-box >/dev/null 2>&1 || die "sing-box 安装后未找到可执行文件。"
  sing-box version | grep -Fq "sing-box version ${SING_BOX_VERSION}" \
    || die "sing-box 版本检查失败。"
  ok "sing-box ${SING_BOX_VERSION} 安装完成，SHA256校验通过"
}

generate_credentials() {
  say "生成随机凭证"

  REALITY_UUID="$(sing-box generate uuid)"
  CDN_UUID="$(sing-box generate uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  WS_PATH="/$(openssl rand -hex 12)"
  SUBSCRIPTION_PATH="/$(openssl rand -hex 24).yaml"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  ACME_ALT_PORT="$((20000 + RANDOM % 10000))"
  while port_is_listening "${ACME_ALT_PORT}"; do
    ACME_ALT_PORT="$((20000 + RANDOM % 10000))"
  done

  local key_output
  key_output="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(
    awk -F': *' '/^PrivateKey:|^Private key:/ {print $2; exit}' <<<"${key_output}"
  )"
  REALITY_PUBLIC_KEY="$(
    awk -F': *' '/^PublicKey:|^Public key:/ {print $2; exit}' <<<"${key_output}"
  )"

  [[ -n "${REALITY_PRIVATE_KEY}" ]] || die "无法解析 REALITY 私钥。"
  [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "无法解析 REALITY 客户端参数（Password/公钥）。"
  ok "Reality、CDN、HY2凭证及随机路径已生成"
}

write_sing_box_config() {
  say "写入 sing-box 配置"
  install -d -m 700 "$(dirname "${SING_BOX_CONFIG}")"

  cat >"${SING_BOX_CONFIG}" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "name": "reality",
          "uuid": "${REALITY_UUID}",
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
            "server_port": ${REALITY_TARGET_PORT}
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-websocket",
      "listen": "127.0.0.1",
      "listen_port": ${WS_LOCAL_PORT},
      "users": [
        {
          "name": "cdn",
          "uuid": "${CDN_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      {
        "ip_is_private": true, "action": "reject"
      },
      {
        "protocol": "bittorrent", "action": "reject"
      }
    ],
    "final": "direct"
  }
}
EOF

  chmod 600 "${SING_BOX_CONFIG}"

  if ! sing-box check -c "${SING_BOX_CONFIG}" >"${TEMP_DIR}/sing-box-config-test.log" 2>&1; then
    cat "${TEMP_DIR}/sing-box-config-test.log" >&2
    die "sing-box 配置检查失败。"
  fi

  grep -Fq "\"uuid\": \"${REALITY_UUID}\"" "${SING_BOX_CONFIG}" \
    || die "sing-box 配置中缺少 Reality UUID。"
  grep -Fq "\"uuid\": \"${CDN_UUID}\"" "${SING_BOX_CONFIG}" \
    || die "sing-box 配置中缺少 CDN UUID。"

  ok "sing-box 格式与 VLESS 用户配置检查通过"
}

write_sing_box_service() {
  say "写入 sing-box 系统服务"

  cat >"${SING_BOX_SERVICE}" <<EOF
[Unit]
Description=sing-box Three-in-One Proxy Core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c ${SING_BOX_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${SING_BOX_SERVICE}"
  ok "sing-box 系统服务已写入"
}

install_caddy() {
  say "安装官方 Caddy"

  curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
    gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
  local caddy_version
  caddy_version="$(caddy version 2>/dev/null)"
  caddy_version="${caddy_version%%$'\n'*}"
  ok "Caddy 安装完成：${caddy_version}"
}

install_hysteria() {
  say "安装官方 Hysteria 2"

  curl -fsSL "${HYSTERIA_INSTALL_URL}" -o "${TEMP_DIR}/install-hysteria.sh"
  if ! bash "${TEMP_DIR}/install-hysteria.sh" \
    >"${TEMP_DIR}/hysteria-install.log" 2>&1; then
    cat "${TEMP_DIR}/hysteria-install.log" >&2
    die "Hysteria 官方安装脚本执行失败。"
  fi

  command -v hysteria >/dev/null 2>&1 ||
    die "Hysteria 安装后未找到可执行文件。"
  systemctl cat "${HYSTERIA_SERVICE}" >/dev/null 2>&1 ||
    die "Hysteria 安装后未找到 systemd 服务。"

  local hysteria_version
  hysteria_version="$(
    hysteria version 2>&1 |
      awk -F':[[:space:]]*' '/^Version:/ {print $2; exit}'
  )" || true
  ok "Hysteria 安装完成：${hysteria_version:-版本未知}"
}

write_hysteria_config() {
  say "写入 Hysteria 2 配置"

  local service_user
  service_user="$(
    systemctl cat "${HYSTERIA_SERVICE}" |
      awk -F= '/^User=/ {print $2; exit}'
  )"
  [[ -n "${service_user}" ]] || die "无法读取 Hysteria 服务用户。"

  install -d -m 750 -o root -g "${service_user}" "$(dirname "${HYSTERIA_CONFIG}")"

  {
    printf 'listen: :%s\n\n' "${HY2_PORT}"
    printf 'acme:\n'
    printf '  domains:\n'
    printf '    - %s\n' "${HY2_DOMAIN}"
    if [[ -n "${ACME_EMAIL}" ]]; then
      printf '  email: %s\n' "${ACME_EMAIL}"
    fi
    printf '  ca: letsencrypt\n'
    printf '  type: http\n'
    printf '  http:\n'
    printf '    altPort: %s\n\n' "${ACME_ALT_PORT}"
    printf 'auth:\n'
    printf '  type: password\n'
    printf '  password: %s\n\n' "${HY2_PASSWORD}"
    printf 'masquerade:\n'
    printf '  type: proxy\n'
    printf '  proxy:\n'
    printf '    url: https://www.debian.org/\n'
    printf '    rewriteHost: true\n'
  } >"${HYSTERIA_CONFIG}"

  chown root:"${service_user}" "${HYSTERIA_CONFIG}"
  chmod 640 "${HYSTERIA_CONFIG}"
  ok "Hysteria配置已生成"
}

write_clash_profile() {
  say "生成 Clash Verge 订阅配置"

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
    uuid: ${REALITY_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SERVER_NAME}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}

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
      path: ${WS_PATH}
      headers:
        Host: ${CDN_DOMAIN}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - VPS-Reality
      - VPS-HY2
      - VPS-CF-CDN
      - DIRECT

rules:
  - MATCH,PROXY
EOF

  install -d -o root -g caddy -m 750 "${SUBSCRIPTION_DIR}"
  install -o root -g caddy -m 640 \
    "${CLASH_PROFILE}" "${SUBSCRIPTION_DIR}${SUBSCRIPTION_PATH}"
  chmod 600 "${CLASH_PROFILE}"
  ok "Clash Verge 本地配置和远程订阅文件已生成"
}

write_caddy_config() {
  say "写入 Caddy 配置"

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

	@sing_box_websocket path ${WS_PATH}
	handle @sing_box_websocket {
		reverse_proxy 127.0.0.1:${WS_LOCAL_PORT}
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
  if ! caddy validate --config "${CADDY_CONFIG}" --adapter caddyfile \
    >"${TEMP_DIR}/caddy-config-test.log" 2>&1; then
    cat "${TEMP_DIR}/caddy-config-test.log" >&2
    die "Caddy 配置检查失败。"
  fi
  ok "Caddy 配置检查通过"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    say "放行 UFW 端口"
    ufw allow 80/tcp
    ufw allow "${REALITY_PORT}/tcp"
    ufw allow "${CDN_PORT}/tcp"
    ufw allow "${HY2_PORT}/udp"
    return
  fi

  # nftables 检测：如果存在活动规则集且不是完全放行状态，给出警告
  # （不自动修改 nftables，因为规则格式多变且容易误伤）
  if command -v nft >/dev/null 2>&1; then
    local ruleset
    ruleset="$(nft list ruleset 2>/dev/null)" || true
    if [[ -n "${ruleset}" && "${ruleset}" != *"policy accept"* ]]; then
      warn "检测到 nftables 规则，但未自动放行端口。"
      printf '    请手动放行 TCP 80、%s、%s 和 UDP %s。\n' \
        "${REALITY_PORT}" "${CDN_PORT}" "${HY2_PORT}" >&2
    fi
  fi
}

start_services() {
  say "启动服务"
  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
  systemctl enable caddy
  systemctl restart caddy

  systemctl is-active --quiet sing-box || {
    journalctl -u sing-box -n 50 --no-pager >&2
    die "sing-box 启动失败。"
  }

  systemctl is-active --quiet caddy || {
    journalctl -u caddy -n 80 --no-pager >&2
    die "Caddy 启动失败，常见原因是 DNS 未生效或 80/8443 端口未放行。"
  }

  systemctl enable "${HYSTERIA_SERVICE}" >/dev/null
  systemctl restart "${HYSTERIA_SERVICE}"

  wait_status "Hysteria 证书和 UDP 监听（最长 120 秒）"
  local elapsed=0
  while (( elapsed < 120 )); do
    if systemctl is-active --quiet "${HYSTERIA_SERVICE}" &&
      udp_port_is_listening "${HY2_PORT}"; then
      printf '\n'
      ok "Hysteria证书已申请成功，并监听UDP ${HY2_PORT}"
      ok "sing-box、Caddy和Hysteria均已设置为开机自动运行"
      return
    fi
    printf '.'
    sleep 5
    elapsed=$((elapsed + 5))
  done

  printf '\n'
  journalctl -u "${HYSTERIA_SERVICE}" -n 100 --no-pager >&2
  die "Hysteria在120秒内未能启动。请检查HY2灰云DNS、TCP 80和UDP 443。"
}

verify_listeners() {
  say "检查端口、证书和三节点完整链路"
  port_is_listening "${REALITY_PORT}" || die "sing-box 没有监听 ${REALITY_PORT}。"
  port_is_listening "${CDN_PORT}" || die "Caddy 没有监听 ${CDN_PORT}。"
  port_is_listening "${WS_LOCAL_PORT}" || die "sing-box 没有监听内部 WebSocket 端口。"
  udp_port_is_listening "${HY2_PORT}" || die "Hysteria 没有监听 UDP ${HY2_PORT}。"
  ok "Reality TCP 443、HY2 UDP 443、CDN 8443和内部WebSocket端口均正常"

  systemctl is-active --quiet "${HYSTERIA_SERVICE}" ||
    die "Hysteria服务已停止。"
  ok "Hysteria服务状态和UDP监听均正常"

  wait_status "Caddy 申请证书（最长 ${CERT_WAIT_SECONDS} 秒）"
  local elapsed=0
  while (( elapsed < CERT_WAIT_SECONDS )); do
    if curl -sS --max-time 8 \
      --resolve "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1" \
      "https://${CDN_DOMAIN}:${CDN_PORT}/" \
      -o /dev/null 2>/dev/null; then
      CDN_TLS_READY=true
      printf '\n'
      ok "TLS 证书已申请成功，域名验证通过"
      break
    fi
    printf '.'
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "${CDN_TLS_READY}" != true ]]; then
    printf '\n'
    warn "证书在 ${CERT_WAIT_SECONDS} 秒内仍未就绪，CDN 节点暂时不能使用。"
    warn "Reality 节点不受影响，可以立即导入测试。"
    warn "检查命令：journalctl -u caddy -n 100 --no-pager"
    return
  fi

  local ws_http_code
  ws_http_code="$(
    curl -sS --http1.1 --max-time 5 \
      --resolve "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1" \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: SGVsbG9Xb3JsZDEyMzQ1Ng==' \
      -o /dev/null -w '%{http_code}' \
      "https://${CDN_DOMAIN}:${CDN_PORT}${WS_PATH}" 2>/dev/null || true
  )"
  [[ "${ws_http_code}" == "101" ]] || {
    journalctl -u caddy -n 50 --no-pager >&2
    die "WebSocket 升级失败（HTTP ${ws_http_code:-无响应}）。请检查 Caddy 路由和路径。"
  }
  ok "WebSocket 请求已由 Caddy 正确转发到 sing-box（HTTP 101）"

  local downloaded_profile="${TEMP_DIR}/clash-verge-download.yaml"
  curl -fsS --max-time 10 \
    --resolve "${CDN_DOMAIN}:${CDN_PORT}:127.0.0.1" \
    "https://${CDN_DOMAIN}:${CDN_PORT}${SUBSCRIPTION_PATH}" \
    -o "${downloaded_profile}" \
    || die "Clash Verge 订阅地址无法读取。"
  cmp -s "${CLASH_PROFILE}" "${downloaded_profile}" \
    || die "订阅地址返回的内容与生成的 Clash 配置不一致。"
  grep -Fq 'name: VPS-HY2' "${downloaded_profile}" \
    || die "远程订阅中没有找到VPS-HY2。"
  ok "Clash Verge订阅包含Reality、HY2和CDN，内容校验一致"
}

write_client_info() {
  say "生成客户端配置"

  local encoded_ws_path
  local cdn_status
  encoded_ws_path="%2F${WS_PATH#/}"
  if [[ "${CDN_TLS_READY}" == true ]]; then
    cdn_status="证书已就绪；切换橙云后即可使用"
  else
    cdn_status="证书尚未就绪；暂时不要使用"
  fi

  REALITY_LINK="vless://${REALITY_UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VPS-Reality"
  HY2_LINK="hysteria2://${HY2_PASSWORD}@${HY2_DOMAIN}:${HY2_PORT}/?sni=${HY2_DOMAIN}&alpn=h3&insecure=0#VPS-HY2"
  CDN_LINK="vless://${CDN_UUID}@${CDN_DOMAIN}:${CDN_PORT}?encryption=none&security=tls&sni=${CDN_DOMAIN}&type=ws&host=${CDN_DOMAIN}&path=${encoded_ws_path}#VPS-CF-CDN"
  CLASH_SUBSCRIPTION_URL="https://${CDN_DOMAIN}:${CDN_PORT}${SUBSCRIPTION_PATH}"

  cat >"${RESULT_FILE}" <<EOF
sing-box 节点信息
生成时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')

============================================================
一、可直接导入的节点链接
============================================================

【Reality 主节点：现在就可以导入测试】
${REALITY_LINK}

【Hysteria 2备用节点：现在就可以导入测试】
${HY2_LINK}

【Cloudflare CDN 备用节点：${cdn_status}】
${CDN_LINK}

以上链接适用于支持对应URL格式的客户端，例如Shadowrocket。
Clash Verge不要导入单节点链接，使用下面的统一订阅。

============================================================
二、Clash Verge / Mihomo
============================================================

完整配置文件：${CLASH_PROFILE}

远程订阅链接：
${CLASH_SUBSCRIPTION_URL}

在 Clash Verge 的「订阅」页面新建远程订阅，粘贴上面的 HTTPS 地址。

============================================================
三、你接下来要做什么
============================================================

1. 测试Reality节点。
2. 测试HY2节点；${HY2_DOMAIN}必须始终保持灰云。
3. Cloudflare中暂时保持${CDN_DOMAIN}为灰云。
4. CDN证书状态：${cdn_status}。
5. 证书就绪后，把${CDN_DOMAIN}切换为橙云。
6. Cloudflare的SSL/TLS加密模式设为「完全（严格）」。
7. 测试CDN节点。
8. Clash Verge使用上方统一订阅，一次获得三个节点。

如果证书尚未就绪，查看原因：
journalctl -u caddy -n 100 --no-pager

服务端配置位置：
sing-box：${SING_BOX_CONFIG}
Hysteria：${HYSTERIA_CONFIG}
Caddy：${CADDY_CONFIG}
Clash Verge：${CLASH_PROFILE}

重要：订阅链接可以读取全部节点配置，等同密码，不要公开。
EOF

  chmod 600 "${RESULT_FILE}"

  printf '\n%s━━━━━━━━━━━━ ━━ 部署完成 ━━ ━━━━━━━━━━━━%s\n' \
    "${COLOR_GREEN}" "${COLOR_RESET}"
  printf '%s  三个节点和 Clash Verge 订阅均已生成%s\n\n' \
    "${COLOR_BOLD}" "${COLOR_RESET}"

  printf '%s[1] Reality 主节点｜现在直接导入测试%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
  printf '%s\n\n' "${REALITY_LINK}"
  printf '%s[2] HY2 备用节点｜现在直接导入测试%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
  printf '%s\n\n' "${HY2_LINK}"
  printf '%s  ! 注意：%s 必须始终保持灰云。%s\n\n' \
    "${COLOR_YELLOW}" "${HY2_DOMAIN}" "${COLOR_RESET}"

  if [[ "${CDN_TLS_READY}" == true ]]; then
    printf '%s[3] CDN 备用节点｜先切换橙云，再导入%s\n' \
      "${COLOR_YELLOW}" "${COLOR_RESET}"
    printf '%s\n\n' "${CDN_LINK}"
    printf '%s接下来：%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
    printf '  1. 分别测试Reality和HY2。\n'
    printf '  2. Cloudflare将%s改成橙云，并设为“完全（严格）”。\n' "${CDN_DOMAIN}"
    printf '  3. 测试CDN节点。\n'
    printf '  4. Clash Verge添加下方统一订阅。\n'
  else
    printf '%s[3] CDN 备用节点｜证书未就绪，暂时不要导入%s\n' \
      "${COLOR_RED}" "${COLOR_RESET}"
    printf '%s\n\n' "${CDN_LINK}"
    printf 'Reality和HY2可以先使用；CDN需要继续排查。\n'
    printf 'CDN 排查命令：journalctl -u caddy -n 100 --no-pager\n'
  fi

  printf '\n%s── 保存位置 ──%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
  printf '  客户端信息：%s\n' "${RESULT_FILE}"
  printf '  重新查看：  cat %s\n' "${RESULT_FILE}"
  printf '\n%s── Clash Verge 远程订阅｜直接复制 ──%s\n' \
    "${COLOR_CYAN}" "${COLOR_RESET}"
  printf '%s\n\n' "${CLASH_SUBSCRIPTION_URL}"
  printf '在 Clash Verge 的“订阅”页面新建远程订阅，粘贴上面的地址。\n'
  printf '%s  ! 注意：订阅链接等同节点密码，不要公开。%s\n' \
    "${COLOR_RED}" "${COLOR_RESET}"
}

check_open_ports_notice() {
  say "防火墙提醒"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q '^Status: active'; then
      printf 'UFW已放行TCP 80、%s、%s和UDP %s。\n' \
        "${REALITY_PORT}" "${CDN_PORT}" "${HY2_PORT}"
    else
      warn "检测到 UFW 但未激活；如果连接不上，请检查 VPS 控制台防火墙。"
    fi
  elif command -v nft >/dev/null 2>&1; then
    local ruleset
    ruleset="$(nft list ruleset 2>/dev/null)" || true
    if [[ -z "${ruleset}" ]]; then
      printf '未检测到 nftables 规则，系统默认放行所有流量。\n'
    fi
  else
    warn "未检测到 UFW 或 nftables；请检查 VPS 控制台防火墙。"
    printf '    需要放行 TCP 80、%s、%s 和 UDP %s。\n' \
      "${REALITY_PORT}" "${CDN_PORT}" "${HY2_PORT}" >&2
  fi
}

main() {
  require_root
  require_debian
  refuse_existing_installation
  read_inputs

  TEMP_DIR="$(mktemp -d)"

  install_base_packages
  enable_bbr
  detect_public_ip
  install_sing_box
  generate_credentials
  write_sing_box_config
  write_sing_box_service
  install_caddy
  install_hysteria
  write_hysteria_config
  write_clash_profile
  write_caddy_config
  configure_firewall
  start_services
  verify_listeners
  check_open_ports_notice
  write_client_info
}

main "$@"
