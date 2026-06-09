# Download and extract MPV for Windows bundling
# This script downloads the latest MPV build and prepares it for bundling

$ErrorActionPreference = "Stop"

$MPV_VERSION = "20240225"
$MPV_DOWNLOAD_URL = "https://sourceforge.net/projects/mpv-player-windows/files/64bit/mpv-x86_64-$MPV_VERSION.7z/download"
$SCRIPT_DIR = $PSScriptRoot
$MPV_DIR = Join-Path $SCRIPT_DIR "mpv"
$TEMP_ARCHIVE = Join-Path $env:TEMP "mpv.7z"

Write-Host "Downloading MPV for Windows..." -ForegroundColor Cyan

# Create mpv directory if it doesn't exist
if (Test-Path $MPV_DIR) {
    Write-Host "MPV directory already exists. Cleaning..." -ForegroundColor Yellow
    Remove-Item -Path $MPV_DIR -Recurse -Force
}
New-Item -ItemType Directory -Path $MPV_DIR | Out-Null

# Download MPV
Write-Host "Downloading MPV from GitHub..." -ForegroundColor Gray
$ProgressPreference = 'SilentlyContinue'

# Use reliable GitHub mirror
$DOWNLOAD_URL = "https://github.com/zhongfly/mpv-winbuild/releases/download/latest/mpv-x86_64.7z"

try {
    # Force TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    Write-Host "Downloading from: $DOWNLOAD_URL" -ForegroundColor Gray
    Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile $TEMP_ARCHIVE -UseBasicParsing -MaximumRedirection 5
    
    # Verify it's actually a 7z file
    $header = [System.IO.File]::ReadAllBytes($TEMP_ARCHIVE) | Select-Object -First 6
    $is7z = ($header[0] -eq 0x37 -and $header[1] -eq 0x7A)  # "7z" magic bytes
    
    if ($is7z) {
        Write-Host "Downloaded MPV archive successfully" -ForegroundColor Green
    }
    else {
        Write-Host "Downloaded file is not a valid 7z archive" -ForegroundColor Red
        Write-Host "File might be an HTML redirect page" -ForegroundColor Yellow
        exit 1
    }
}
catch {
    Write-Host "Failed to download MPV: $_" -ForegroundColor Red
    exit 1
}

# Extract MPV
Write-Host "Extracting MPV..." -ForegroundColor Cyan

# Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# Find 7-Zip
$7zipPaths = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe",
    (Get-Command 7z -ErrorAction SilentlyContinue).Source
)

$7zipPath = $7zipPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($7zipPath) {
    Write-Host "Using 7-Zip: $7zipPath" -ForegroundColor Gray
    & $7zipPath x $TEMP_ARCHIVE -o"$MPV_DIR" -y | Out-Null
    Write-Host "Extracted with 7-Zip" -ForegroundColor Green
}
else {
    Write-Host "7-Zip not found. Please install 7-Zip to extract the archive." -ForegroundColor Red
    Write-Host "Archive location: $TEMP_ARCHIVE" -ForegroundColor Yellow
    Write-Host "Extract to: $MPV_DIR" -ForegroundColor Yellow
    Write-Host "You can install 7-Zip with: winget install 7zip.7zip" -ForegroundColor Cyan
    exit 1
}

# Verify mpv.exe exists
$mpvExe = Get-ChildItem -Path $MPV_DIR -Recurse -Filter "mpv.exe" | Select-Object -First 1
if ($mpvExe) {
    Write-Host "MPV executable found: $($mpvExe.FullName)" -ForegroundColor Green
    
    # Move files to root if they're in a subdirectory
    if ($mpvExe.Directory.FullName -ne $MPV_DIR) {
        Write-Host "Moving files to root directory..." -ForegroundColor Cyan
        Get-ChildItem -Path $mpvExe.Directory.FullName | Move-Item -Destination $MPV_DIR -Force
    }
    
    # Verify final structure
    $finalMpvExe = Join-Path $MPV_DIR "mpv.exe"
    if (Test-Path $finalMpvExe) {
        Write-Host "" -ForegroundColor Green
        Write-Host "SUCCESS" -ForegroundColor Green
        Write-Host "MPV installed to: $MPV_DIR" -ForegroundColor Cyan
        Write-Host "Executable: $finalMpvExe" -ForegroundColor Cyan
        
        # Get version
        try {
            $version = & $finalMpvExe --version | Select-Object -First 1
            Write-Host "Version: $version" -ForegroundColor Gray
        }
        catch {
            Write-Host "Could not get version" -ForegroundColor Yellow
        }
        
        Write-Host ""
        Write-Host "MPV will be bundled with the Windows app build." -ForegroundColor Green
    }
    else {
        Write-Host "Error: mpv.exe not in expected location" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "Error: mpv.exe not found in extracted archive" -ForegroundColor Red
    exit 1
}

# Cleanup
Write-Host "Cleaning up temporary files..." -ForegroundColor Gray
Remove-Item -Path $TEMP_ARCHIVE -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Run: flutter build windows" -ForegroundColor White
Write-Host "2. MPV will be automatically bundled" -ForegroundColor White
Write-Host "3. Your app will use the bundled MPV executable" -ForegroundColor White
