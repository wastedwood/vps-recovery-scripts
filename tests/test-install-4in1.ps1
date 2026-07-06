$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'install-4in1.sh'
$content = Get-Content -Raw $scriptPath
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Contains([string]$Pattern, [string]$Description) {
    if ($content -notmatch $Pattern) {
        $failures.Add("missing: $Description")
    }
}

function Assert-NotContains([string]$Pattern, [string]$Description) {
    if ($content -match $Pattern) {
        $failures.Add("forbidden: $Description")
    }
}

Assert-Contains 'readonly WGCF_VERSION="2\.2\.31"' 'pinned wgcf version'
Assert-Contains 'readonly WGCF_SHA256_AMD64="69147e1a517c66129edd8ac8cb60484d6c9515178d7b4a2f95e3c925f225572a"' 'wgcf amd64 checksum'
Assert-Contains 'readonly WGCF_SHA256_ARM64="b9bdbdeaa3f9f4ba741ba55b8bd94c24f7166c27668eb7e8192ccf9746961182"' 'wgcf arm64 checksum'
Assert-Contains 'readonly ROUTE_WAIT_SECONDS="60"' 'bounded runtime route readiness wait'
Assert-Contains '"endpoints"\s*:\s*\[' 'Sing-box endpoint section'
Assert-Contains '"type"\s*:\s*"wireguard"' 'WireGuard endpoint'
Assert-Contains '"tag"\s*:\s*"warp-out"' 'WARP route tag'
Assert-Contains '"acme"\s*:\s*\{' 'Sing-box ACME configuration'
Assert-Contains '"disable_tls_alpn_challenge"\s*:\s*true' 'HTTP-only ACME challenge'
Assert-Contains 'ExecStart=.*--url http://127\.0\.0\.1:(?<!\\)\$\{ARGO_WS_LOCAL_PORT\}' 'cloudflared direct Argo target expanded while writing service'
Assert-Contains 'warp=on' 'WARP runtime verification'
Assert-Contains 'wait_for_routes\(\)' 'route readiness retry function'
Assert-Contains "sed -n 's/\^PrivateKey\[\[:space:\]\]\*=\[\[:space:\]\]\*//p'" 'private key parser preserves Base64 padding'
Assert-Contains "sed -n 's/\^PublicKey\[\[:space:\]\]\*=\[\[:space:\]\]\*//p'" 'public key parser preserves Base64 padding'
Assert-Contains '--resume-after-config-failure' 'safe resume mode for step 9 failure'

Assert-NotContains 'install_caddy' 'Caddy installer'
Assert-NotContains '/etc/caddy' 'Caddy configuration path'
Assert-NotContains 'caddy\.service' 'Caddy systemd dependency'
Assert-NotContains 'pkg\.cloudflareclient\.com' 'official WARP APT repository'
Assert-NotContains 'apt-get install[^\n]*cloudflare-warp' 'official WARP package install'
Assert-NotContains 'warp-svc' 'official WARP daemon'
Assert-NotContains 'warp-cli' 'official WARP CLI'
Assert-NotContains 'WARP_PROXY_PORT' 'WARP SOCKS proxy'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    Write-Error "$($failures.Count) architecture assertion(s) failed" -ErrorAction Continue
    exit 1
}

Write-Host 'PASS: install-4in1 architecture assertions'
