# VPS Recovery Scripts

## Sing-box四合一

唯一代理内核为Sing-box，一次部署四个客户端节点：

- VLESS + Reality，VPS原生出口
- VLESS + Reality，Cloudflare WARP出口
- Hysteria 2
- VLESS + WebSocket + Cloudflare Tunnel（Argo）

Sing-box同时负责HY2自动证书和WARP WireGuard出口。辅助组件只有
`cloudflared`；不安装Caddy，也不安装Cloudflare官方WARP客户端。

> WARP注册使用一次性的非官方`wgcf`工具。脚本会校验下载文件，提取凭据后立即清理；
> Cloudflare如果改变未公开的注册接口，WARP步骤可能失效，脚本会明确停止而不会冒充成功。

### 前置准备

在Cloudflare准备两个不同的子域名：

- `hy2.example.com`：始终保持灰云
- `argo.example.com`：绑定固定Cloudflare Tunnel，服务地址设置为 `http://localhost:10001`

准备该固定Tunnel的Token。Token输入时不会显示，也不会写入客户端文件或终端总结。

服务器和云防火墙需要放行TCP 80、TCP 443和UDP 443。TCP 80只用于Sing-box向
Let's Encrypt申请和续期HY2证书，不能被其他程序占用。

### 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-4in1.sh)
```

安装完成后，四条节点链接保存在`/root/sing-box-client-info.txt`，Clash Verge / Mihomo
配置保存在`/root/clash-verge.yaml`。取消远程订阅服务后，不会把秘密配置暴露为公网URL。

## 已实测三合一

一次部署三条独立代理通道：

- VLESS + Reality：TCP 443
- Hysteria 2：UDP 443
- VLESS + WebSocket + Cloudflare CDN：TCP 8443

同时生成 Clash Verge / Mihomo 的随机 HTTPS 订阅，并自动启用 BBR + fq。

## 前置准备

在 Cloudflare 创建两条指向新 VPS IPv4 的 A 记录：

- `cdn.example.com`：运行脚本时保持灰云，完成后切换橙云
- `hy2.example.com`：始终保持灰云

服务器需要允许：

- TCP：22（或自定义 SSH 端口）、80、443、8443
- UDP：443

## 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-3in1.sh)
```

脚本不覆盖已有 Xray、Caddy 或 Hysteria 部署。

## 安装结果

脚本完成后会输出：

- Reality 节点链接
- Hysteria 2 节点链接
- Cloudflare CDN 节点链接
- Clash Verge / Mihomo 统一订阅地址

CDN证书成功后，再把CDN子域名切换为橙云，并将Cloudflare SSL/TLS模式设为“完全（严格）”。HY2子域名不能开启橙云。
