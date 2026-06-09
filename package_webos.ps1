$source = "build\web"
$destination = "zapshare_webos_build.zip"

If (Test-Path $destination) {
    Remove-Item $destination
}

Compress-Archive -Path "$source\*" -DestinationPath $destination

Write-Host "Zipped web build to $destination"
Write-Host "Location: $(Convert-Path $destination)"
Write-Host "You can now use 'ares-package' on the build/web folder or use this zip for other installation methods."
