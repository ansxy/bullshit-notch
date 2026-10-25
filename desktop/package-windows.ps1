$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path (Join-Path $Root "desktop/Cargo.toml"))) {
    $Root = Get-Location
}
Set-Location $Root

$Name = "bullshit-notch-windows-x86_64"
$Dist = Join-Path $Root "dist"
$Stage = Join-Path $Dist $Name
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

cargo build --manifest-path desktop/Cargo.toml --release --target x86_64-pc-windows-msvc
$Bin = Join-Path $Root "desktop/target/x86_64-pc-windows-msvc/release/bullshit-notch-desktop.exe"
if (-not (Test-Path $Bin)) {
    $Bin = Join-Path $Root "desktop/target/release/bullshit-notch-desktop.exe"
}
Copy-Item $Bin (Join-Path $Stage "bullshit-notch.exe")
@"
BullshitNotch desktop (Windows)

  bullshit-notch.exe --demo
  bullshit-notch.exe --open --demo

Tray icon: Settings / Quit. Child processes use CREATE_NO_WINDOW.
"@ | Set-Content (Join-Path $Stage "README.txt")

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
$Zip = Join-Path $Dist "$Name.zip"
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path $Stage -DestinationPath $Zip
Write-Host "wrote $Zip"
