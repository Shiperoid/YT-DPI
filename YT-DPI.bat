@echo off
setlocal
REM Оболочка: запускает YT-DPI.ps1 из той же папки. При отсутствии .ps1 — однократная загрузка с GitHub.
cd /d "%~dp0"
chcp 65001 >nul

where /q pwsh.exe
if not errorlevel 1 (
    set "PS_EXE=pwsh.exe"
) else (
    set "PS_EXE=powershell.exe"
)

set "SCRIPT_PATH=%~dp0YT-DPI.ps1"
if not exist "%SCRIPT_PATH%" (
    echo [YT-DPI] YT-DPI.ps1 not found next to this file. Downloading from GitHub...
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $root=Split-Path -LiteralPath $args[0] -Parent; $out=Join-Path $root 'YT-DPI.ps1'; $u='https://raw.githubusercontent.com/Shiperoid/YT-DPI/master/YT-DPI.ps1'; $wc=New-Object System.Net.WebClient; $wc.Headers.Add('User-Agent','YT-DPI/3.0-bootstrap'); $wc.DownloadFile($u,$out); if ((Get-Item -LiteralPath $out).Length -lt 8000) { Remove-Item -LiteralPath $out -Force; throw 'Download failed integrity' }" "%~f0"
    if errorlevel 1 (
        echo [YT-DPI] Could not download YT-DPI.ps1. Place it next to YT-DPI.bat from https://github.com/Shiperoid/YT-DPI/releases
        exit /b 1
    )
)

title YT-DPI v3.0
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
endlocal
exit /b %ERRORLEVEL%
