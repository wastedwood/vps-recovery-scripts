# Changelog

## v0.1.0 - 2026-07-06

### Added

- Added a four-node Sing-box installer for Reality direct, Reality-WARP, Hysteria 2, and Argo WebSocket.
- Added Sing-box-native ACME certificate management for Hysteria 2.
- Added a checksum-verified, one-time `wgcf` registration flow and a native Sing-box WireGuard endpoint for WARP.
- Added architecture regression tests and a safe resume mode for configuration-check failures.

### Changed

- Removed Caddy and the official Cloudflare WARP client from the four-node deployment.
- Changed the fixed Cloudflare Tunnel origin from `http://localhost:10002` to `http://localhost:10001`.
- Replaced the public subscription URL with protected local client files under `/root`.

### Fixed

- Preserved trailing Base64 padding when parsing WARP WireGuard private and public keys.
- Added bounded readiness checks for certificate issuance, WARP egress, and Argo WebSocket connectivity.
