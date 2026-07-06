# Sing-box Native WARP / No-Caddy Design

## Goal

Refactor `install-4in1.sh` so a fresh Debian 12/13 VPS deploys four client nodes without Caddy or the official Cloudflare WARP client:

1. Reality with direct VPS egress.
2. Reality with Cloudflare WARP egress.
3. Hysteria 2.
4. VLESS WebSocket through a fixed Cloudflare Tunnel.

## Architecture

- Sing-box remains the only proxy core.
- Sing-box obtains and renews the HY2 certificate through its built-in ACME provider. HTTP-01 uses public TCP 80; TLS-ALPN is disabled because Reality occupies TCP 443.
- `wgcf` is downloaded at a pinned version, checksum-verified, used once to register a WARP device and generate WireGuard credentials, then removed with the temporary directory.
- The WARP credentials become a Sing-box WireGuard endpoint. The `reality-warp` user routes to that endpoint.
- cloudflared forwards the fixed Tunnel directly to the Sing-box WebSocket listener on `127.0.0.1:10001`.
- No web server is installed. The generated Clash profile is stored at `/root/clash-verge.yaml`; remote HTTPS subscription hosting is removed.

## Inputs and prerequisites

- Fresh Debian 12 or 13 VPS.
- Public TCP 80 and 443, and UDP 443 allowed.
- HY2 DNS A record points directly to the VPS and remains DNS-only (gray cloud).
- A fixed Cloudflare Tunnel public hostname is configured to use `http://localhost:10001`.
- The user supplies the Tunnel token and may supply an ACME email.

## Failure handling

- Refuse existing proxy, cloudflared, Caddy, WARP, or conflicting service installations.
- Validate DNS before installation.
- Verify every downloaded binary checksum.
- Fail if WARP registration/profile parsing is incomplete.
- Run `sing-box check` before starting the service.
- Verify Reality/HY2/Argo listeners, public Argo WebSocket HTTP 101, ACME certificate availability through the running HY2 listener, and WARP `warp=on`.
- Print the relevant service journal on startup failure.

## Security

- Use `umask 077` and mode `0600` for generated client information, profiles, configuration, and Tunnel token.
- Do not print the Tunnel token or WARP private key.
- Reject BitTorrent on all routes.

## Compatibility trade-off

The embedded WARP route uses the unofficial `wgcf` registration client and Cloudflare's WireGuard service. It removes the slow official package installation and persistent `warp-svc`, but Cloudflare may change the undocumented registration behavior. A failure must stop clearly rather than silently falling back to direct egress.

## Verification

- `bash -n install-4in1.sh`
- `shellcheck install-4in1.sh` when available
- Generate a representative configuration and validate it with pinned Sing-box 1.13.14.
- Static assertions confirm there are no Caddy or official WARP-client installation/runtime references.
- README prerequisites, architecture, and install command match the script.
