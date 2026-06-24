# VPS Recovery Scripts

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
