# jikkyo-player Windows installer (PowerShell)
#
# Usage:
#   git clone <repo> "$env:APPDATA\mpv\scripts\jikkyo-player"
#   cd "$env:APPDATA\mpv\scripts\jikkyo-player"
#   .\install.ps1
#
# Options:
#   .\install.ps1 -NoArib        # ARIB字幕なし

param(
    [switch]$NoArib
)

$ErrorActionPreference = "Stop"

# Detect mpv config dir from install location
$ScriptRoot = $PSScriptRoot
$MpvDir = (Resolve-Path (Join-Path $ScriptRoot "..\..")).Path
$OptsDir = Join-Path $MpvDir "script-opts"
$VendorDir = Join-Path $ScriptRoot "vendor"
$AribRepo = "https://github.com/Jasaj4/arib-ts2ass.js.git"
$AribDir = Join-Path $VendorDir "arib-ts2ass.js"

# --- Install core ---

# Add CLI to PATH via user PATH environment variable
$BinDir = Join-Path $ScriptRoot "bin"
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("PATH", "$UserPath;$BinDir", "User")
    Write-Host "CLI: $BinDir をユーザーPATHに追加しました"
} else {
    Write-Host "CLI: $BinDir は既にPATHに含まれています"
}

# mpv.conf: sub-ass-use-video-data=none
$MpvConf = Join-Path $MpvDir "mpv.conf"
if (Test-Path $MpvConf) {
    $content = Get-Content $MpvConf -Raw -ErrorAction SilentlyContinue
    if ($content -match '(?m)^sub-ass-use-video-data=') {
        $content = $content -replace '(?m)^sub-ass-use-video-data=.*', 'sub-ass-use-video-data=none'
        Set-Content -Path $MpvConf -Value $content -NoNewline
    } else {
        Add-Content -Path $MpvConf -Value "`n# 日本の放送用幅1440→1920字幕まで伸ばされる対策`nsub-ass-use-video-data=none"
    }
} else {
    @"

# 日本の放送用幅1440→1920字幕まで伸ばされる対策
sub-ass-use-video-data=none
"@ | Set-Content -Path $MpvConf
}

# --- Install ARIB (optional) ---
if (-not $NoArib) {
    if (-not (Test-Path $VendorDir)) {
        New-Item -ItemType Directory -Path $VendorDir -Force | Out-Null
    }

    if (Test-Path (Join-Path $AribDir ".git")) {
        Write-Host "arib-ts2ass.js: 更新中..."
        Push-Location $AribDir
        git pull --recurse-submodules
        npm install
        Pop-Location
    } else {
        Write-Host "arib-ts2ass.js: インストール中..."
        git clone --recursive $AribRepo $AribDir
        Push-Location $AribDir
        npm install
        Pop-Location
    }
}

# --- Summary ---
Write-Host ""
Write-Host "=== セットアップ完了 ==="
Write-Host "mpv config:    $MpvDir"
Write-Host "スクリプト:    $ScriptRoot\main.lua"
Write-Host "設定ファイル:  $OptsDir\jikkyo-player.conf (手動作成)"
if (-not $NoArib) {
    Write-Host "ARIB字幕:     $AribDir"
}
Write-Host "CLI:           $BinDir\jikkyo-player.bat"
Write-Host ""
