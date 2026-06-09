<#
Generate a self-signed certificate (PEM) with an IP SAN and place the cert+key
into `assets/certs/` so the app can load them from assets at runtime.

Usage (PowerShell):
  # Default IP (192.168.0.100)
  .\generate_selfsigned_cert.ps1

  # Custom IP
  .\generate_selfsigned_cert.ps1 -Ip 192.168.1.42

Requirements:
  - OpenSSL in PATH (https://www.openssl.org/) OR
  - Windows with OpenSSL available (recommended). If you don't have OpenSSL,
    install it or generate certificate using other tools and copy files to
    assets/certs/

Security:
  - This generates a self-signed certificate intended for local/testing only.
  - Do NOT ship private keys in public repositories.
#>

param(
    [string]$Ip = "192.168.0.100",
    [string]$OutDir = "assets/certs"
)

$ErrorActionPreference = 'Stop'

Write-Host "Generating self-signed cert for IP SAN: $Ip"

# Ensure output directory exists
$fullOut = Join-Path -Path (Get-Location) -ChildPath $OutDir
if (-not (Test-Path $fullOut)) {
    New-Item -ItemType Directory -Path $fullOut | Out-Null
}

# Create an OpenSSL config with SAN for the IP
$config = @"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $Ip

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = $Ip
"@

$configPath = Join-Path $fullOut "openssl_san.cnf"
$config | Out-File -Encoding ascii -FilePath $configPath

$keyPath = Join-Path $fullOut "server.key"
$crtPath = Join-Path $fullOut "server.crt"

# Check for openssl
$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if ($null -eq $openssl) {
    Write-Error "OpenSSL not found in PATH. Please install OpenSSL or generate PEM files by other means and place them in $OutDir"
    exit 1
}

Write-Host "Running OpenSSL to create key and certificate..."
$cmd = "req -x509 -nodes -days 365 -newkey rsa:2048 -keyout `"$keyPath`" -out `"$crtPath`" -config `"$configPath`""
& openssl $cmd

if (Test-Path $keyPath -and Test-Path $crtPath) {
    Write-Host "Certificate and key generated successfully:"
    Write-Host "  $crtPath"
    Write-Host "  $keyPath"
    Write-Host "NOTE: Rebuild the app after generation so Flutter includes the new assets (run `flutter pub get` then rebuild)."
} else {
    Write-Error "Failed to generate certificate/key. Check OpenSSL output above."
    exit 1
}
