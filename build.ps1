# Requires -Version 5.1
# Repacks src/cleaner.ps1 into the single-file .bat.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#
# The .bat is a generated artifact: an ASCII-only cmd wrapper plus the
# PowerShell body as "#B64#" base64 lines. Edit src/cleaner.ps1 instead.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

$srcPath = Join-Path $root 'src\cleaner.ps1'
if (-not (Test-Path -LiteralPath $srcPath)) { throw "missing source: $srcPath" }

$bats = @(Get-ChildItem -LiteralPath $root -Filter '*.bat' -File)
if ($bats.Count -ne 1) { throw "expected exactly one .bat in $root, found $($bats.Count)" }
$batPath = $bats[0].FullName

# LF internally so the payload bytes do not depend on the checkout's eol setting
$text = (Get-Content -LiteralPath $srcPath -Raw -Encoding UTF8) -replace "`r`n", "`n"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
$b64 = [System.Convert]::ToBase64String($bytes)

$payload = @()
for ($i = 0; $i -lt $b64.Length; $i += 100) {
    $payload += 'REM #B64#' + $b64.Substring($i, [Math]::Min(100, $b64.Length - $i))
}

$header = @'
@echo off
setlocal
chcp 65001 >nul 2>&1
REM ============================================================
REM  Cache cleaner - single file, no companion file needed.
REM
REM  GENERATED FILE - DO NOT EDIT THE "#B64#" BLOCK BY HAND.
REM    source of truth : src/cleaner.ps1
REM    rebuild         : powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
REM
REM  The PowerShell body is stored as base64 so that this file stays
REM  100% ASCII. A UTF-8 batch file containing Chinese text can make
REM  cmd misparse or abort its own contents.
REM
REM  Usage: double-click to run. Optional switches (no spaces inside an
REM  argument, they are split on whitespace):
REM    -DryRun  -Yes  -IncludeAdmin  -MinAgeDays N  -NoPause  -Report
REM ============================================================

set "CLEANCACHE_SRC=%~f0"
set "CC_ARGS=%*"
set "CC_PAUSE=1"
if not "%CC_ARGS%"=="%CC_ARGS:-NoPause=%" set "CC_PAUSE=0"

where powershell >nul 2>&1
if errorlevel 1 (
    where pwsh >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] PowerShell is not available on this computer.
        echo.
        if "%CC_PAUSE%"=="1" pause
        exit /b 1
    )
    set "CC_PS=pwsh"
) else (
    set "CC_PS=powershell"
)

"%CC_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$c = @(Get-Content -LiteralPath $env:CLEANCACHE_SRC -Encoding UTF8 | Where-Object { $_.StartsWith('REM #B64#') } | ForEach-Object { $_.Substring(9) }); if ($c.Count -lt 1) { Write-Host '[ERROR] payload missing'; exit 9 }; $b = ($c -join ''); if (($b.Length -band 3) -ne 0) { Write-Host '[ERROR] payload truncated'; exit 8 }; $src = ''; try { $src = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b)) } catch { Write-Host '[ERROR] payload corrupt'; exit 8 }; $av = @(); $raw = [Environment]::GetEnvironmentVariable('CC_ARGS'); if ($raw -and $raw.Trim()) { $av = @($raw -split '\s+') }; & ([System.Management.Automation.ScriptBlock]::Create($src)) @av"
set "EC=%ERRORLEVEL%"

if not "%EC%"=="0" (
    echo.
    echo [ERROR] The script stopped with exit code %EC%.
    echo.
)
if "%CC_PAUSE%"=="1" pause
endlocal
'@

$lines = @($header -split "`r?`n") + $payload
$out = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($batPath, $out, [System.Text.Encoding]::ASCII)

# verify: the shipped file must decode back to exactly what we encoded
$check = @(Get-Content -LiteralPath $batPath -Encoding UTF8 |
    Where-Object { $_.StartsWith('REM #B64#') } | ForEach-Object { $_.Substring(9) })
$decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($check -join '')))
if ($decoded -ne $text) { throw 'roundtrip verification failed: decoded payload differs from src/cleaner.ps1' }

$raw = [System.IO.File]::ReadAllBytes($batPath)
$high = 0
foreach ($x in $raw) { if ($x -gt 126) { $high++ } }
if ($high -gt 0) { throw "output contains $high non-ASCII bytes" }

Write-Host ('built {0}: {1} source bytes -> {2} payload lines, ASCII clean' -f (Split-Path $batPath -Leaf), $bytes.Length, $payload.Count)
