# wezterm/install.ps1 — Install WezTerm on Windows and deploy config
# Run from PowerShell (not WSL)

$ErrorActionPreference = "Stop"

Write-Host "`n==> WezTerm setup (Windows)" -ForegroundColor Blue

# ── Install WezTerm ──

$weztermInstalled = Get-Command wezterm -ErrorAction SilentlyContinue
if ($weztermInstalled) {
    Write-Host "[INFO] WezTerm already installed" -ForegroundColor Green
} else {
    Write-Host "[INFO] Installing WezTerm via winget..." -ForegroundColor Green
    winget install wez.wezterm --accept-source-agreements --accept-package-agreements
}

# ── Install JetBrains Mono Nerd Font (from official Nerd Fonts GitHub releases) ──

Write-Host "`n==> Checking JetBrains Mono Nerd Font" -ForegroundColor Blue

$fontInstalled = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -Filter "JetBrainsMonoNerdFont*.ttf" -ErrorAction SilentlyContinue
if (-not $fontInstalled) {
    $fontInstalled = Get-ChildItem "$env:windir\Fonts" -Filter "JetBrainsMonoNerdFont*.ttf" -ErrorAction SilentlyContinue
}
if ($fontInstalled) {
    Write-Host "[INFO] JetBrains Mono Nerd Font already installed" -ForegroundColor Green
} else {
    Write-Host "[INFO] Downloading JetBrains Mono Nerd Font from official Nerd Fonts release..." -ForegroundColor Green
    $nerdFontsVersion = "v3.3.0"
    $zipUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/$nerdFontsVersion/JetBrainsMono.zip"
    $tempZip = Join-Path $env:TEMP "JetBrainsMono.zip"
    $tempDir = Join-Path $env:TEMP "JetBrainsMono"

    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip
    Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force

    $fontsDir = (New-Object -ComObject Shell.Application).Namespace(0x14)
    Get-ChildItem -Path $tempDir -Filter "*.ttf" | ForEach-Object {
        $fontsDir.CopyHere($_.FullName, 0x10)
    }

    Remove-Item $tempZip -Force
    Remove-Item $tempDir -Recurse -Force
    Write-Host "[INFO] JetBrains Mono Nerd Font installed" -ForegroundColor Green
}

# ── Deploy config ──

Write-Host "`n==> Deploying WezTerm config" -ForegroundColor Blue

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configSource = Join-Path $ScriptRoot "config\wezterm.lua"
$configTarget = Join-Path $HOME ".wezterm.lua"

if (Test-Path $configTarget) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $HOME ".shining-dev-setup-backup\$timestamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Move-Item -Path $configTarget -Destination (Join-Path $backupDir ".wezterm.lua")
    Write-Host "[WARN] Backed up existing config to $backupDir" -ForegroundColor Yellow
}

Copy-Item -Path $configSource -Destination $configTarget
Write-Host "[INFO] Deployed: $configTarget" -ForegroundColor Green

Write-Host "`n==> WezTerm setup complete" -ForegroundColor Blue
