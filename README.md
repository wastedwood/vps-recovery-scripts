# VPS Recovery Scripts

## Sing-box五合一（待真实VPS实测）

唯一代理内核为Sing-box，一次部署五个客户端节点：

- VLESS + Reality，VPS原生出口
- VLESS + Reality，Cloudflare WARP出口
- Hysteria 2
- VLESS + WebSocket + Cloudflare CDN
- VLESS + WebSocket + Cloudflare Tunnel（Argo）

辅助组件为Caddy、cloudflared和Cloudflare官方WARP客户端。

### 前置准备

在Cloudflare准备三个不同的子域名：

- `cdn.example.com`：运行脚本时保持灰云，成功后切换橙云
- `hy2.example.com`：始终保持灰云
- `argo.example.com`：绑定固定Cloudflare Tunnel，服务地址设置为 `http://localhost:10001`

准备该固定Tunnel的Token。Token输入时不会显示，也不会写入订阅或终端总结。

### 一行安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-5in1.sh)
```

> 当前五合一脚本已通过Bash语法、静态安全契约和Sing-box 1.13.14配置解析；尚未在全新VPS完成五条真实链路验收。正式恢复前继续保留下面的三合一方案。

如果旧版脚本在WARP软件源处报 `NO_PUBKEY 6E2DD2174FA1C3BA` 并中止，使用专用安全续跑入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wastedwood/vps-recovery-scripts/main/install-5in1.sh) --resume-after-warp
```

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
