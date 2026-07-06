# Sing-box Native WARP / No-Caddy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Caddy and the official WARP client with Sing-box built-in ACME and WireGuard while retaining four client nodes.

**Architecture:** Sing-box owns Reality, HY2 with ACME, Argo WebSocket, and a WireGuard endpoint populated by a temporary pinned `wgcf` binary. cloudflared connects directly to the Argo listener; client profiles are stored locally instead of hosted remotely.

**Tech Stack:** Bash, Sing-box 1.13.14, cloudflared 2026.6.1, wgcf 2.2.31, systemd, JSON, PowerShell/Python static tests.

---

### Task 1: Add architecture regression tests

**Files:**
- Create: `tests/test-install-4in1.ps1`
- Test: `install-4in1.sh`

- [x] Write assertions that the installer contains pinned wgcf hashes, a WireGuard endpoint, Sing-box ACME with HTTP challenge, direct Argo port 10001, and no Caddy or official WARP installation calls.
- [x] Run `pwsh -NoProfile -File tests/test-install-4in1.ps1`; expect failure against the old installer.
- [x] Commit the test with the implementation after it passes.

### Task 2: Refactor the installer

**Files:**
- Modify: `install-4in1.sh`
- Test: `tests/test-install-4in1.ps1`

- [x] Remove Caddy constants, installation, configuration, certificate polling, hosted subscription, and service checks.
- [x] Remove Cloudflare WARP APT repository, package, daemon, SOCKS proxy, and checks.
- [x] Add pinned wgcf download/checksum selection for amd64 and arm64.
- [x] Register a WARP profile in the temporary directory and parse private key, addresses, peer public key, endpoint, and allowed IPs with strict non-empty validation.
- [x] Add a Sing-box WireGuard endpoint tagged `warp-out` and route `reality-warp` through it.
- [x] Configure HY2 TLS with Sing-box inline ACME, HTTP-01 enabled and TLS-ALPN disabled.
- [x] Forward cloudflared directly to `127.0.0.1:10001` and generate local Clash/client files.
- [x] Validate with `bash -n`, static tests, and Sing-box configuration parsing.

### Task 3: Update operator documentation

**Files:**
- Modify: `README.md`

- [x] Document the no-Caddy/no-warp-svc architecture, TCP 80 ACME prerequisite, Argo service target `http://localhost:10001`, local profile location, and unofficial wgcf compatibility risk.
- [x] Confirm documented nodes and one-line install command match the script.

### Task 4: Verify and publish

**Files:**
- Verify: `install-4in1.sh`, `README.md`, `tests/test-install-4in1.ps1`

- [x] Run `bash -n install-4in1.sh` in a Bash environment.
- [x] Run the regression test; ShellCheck is not installed in this workspace.
- [x] Review `git diff` and ensure unrelated untracked directories are not staged.
- [ ] Commit the implementation, push `main` to `origin`, and report the raw GitHub Bash command.
