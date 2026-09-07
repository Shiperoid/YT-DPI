#requires -Version 5.1
<#
.SYNOPSIS
  Compiles TLS C# snippet extracted from YT-DPI.ps1 (fresh process).
  Traceroute/Deep Trace removed in 3.0 — TracePath is optional legacy no-op.
#>
param(
    [Parameter(Mandatory)][string]$TlsPath,
    [string]$TracePath = $null,
    [string]$RepoRoot = $null,
    [switch]$SkipSmoke,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function Write-AddTypeStep {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail = ''
    )
    $line = '[{0}] {1}' -f $Status, $Phase
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line += (' — {0}' -f $Detail) }
    $color = switch ($Status) {
        'PASS' { if ($Quiet) { 'Gray' } else { 'Green' }; break }
        'FAIL' { 'Red'; break }
        default { 'DarkGray' }
    }
    Write-Host $line -ForegroundColor $color
}

if (-not (Test-Path -LiteralPath $TlsPath)) {
    Write-AddTypeStep -Status FAIL -Phase 'read TLS path' -Detail $TlsPath
    throw "TLS file missing: $TlsPath"
}
Write-AddTypeStep -Status PASS -Phase 'read snippet paths'

$tls = [System.IO.File]::ReadAllText($TlsPath, [System.Text.Encoding]::UTF8)
Write-AddTypeStep -Status PASS -Phase 'read snippet UTF-8'

if ([string]::IsNullOrWhiteSpace($tls)) {
    Write-AddTypeStep -Status FAIL -Phase 'TLS snippet empty'
    throw 'TLS snippet is empty after extract.'
}
if ($tls -notmatch '(?m)\bclass\s+TlsScanner\b') {
    Write-AddTypeStep -Status FAIL -Phase 'TLS snippet sanity' -Detail 'no type TlsScanner'
    throw 'TLS snippet sanity: expected type name TlsScanner.'
}
if ($TracePath -and (Test-Path -LiteralPath $TracePath)) {
    Write-AddTypeStep -Status SKIP -Phase 'traceroute snippet' -Detail 'Deep Trace removed in 3.0'
}
Write-AddTypeStep -Status PASS -Phase 'snippet sanity'

$swCompile = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Add-Type -TypeDefinition $tls -ErrorAction Stop
} catch {
    Write-AddTypeStep -Status FAIL -Phase 'Add-Type TLS (TlsScanner)'
    Write-Host ('[FAIL] TlsPath={0}' -f $TlsPath) -ForegroundColor Red
    Write-Host ('[FAIL] Exception: {0}' -f $_.Exception) -ForegroundColor Red
    throw
}
$swCompile.Stop()

try {
    $null = [TlsScanner]
} catch {
    Write-AddTypeStep -Status FAIL -Phase 'type resolve TlsScanner'
    throw "TlsScanner type not visible after Add-Type: $_"
}
Write-AddTypeStep -Status PASS -Phase 'Add-Type compile + type resolve' -Detail ('{0} ms' -f [int]$swCompile.Elapsed.TotalMilliseconds)

if ($RepoRoot -and -not $SkipSmoke) {
    $smoke = Join-Path $PSScriptRoot 'smoke-yt-dpi-engines.ps1'
    if (-not (Test-Path -LiteralPath $smoke)) {
        Write-AddTypeStep -Status FAIL -Phase 'locate smoke script'
        throw "Smoke script missing: $smoke"
    }
    $smokeArgs = @{ RepoRoot = $RepoRoot }
    if ($Quiet) { $smokeArgs['Quiet'] = $true }
    & $smoke @smokeArgs
    if (-not $?) {
        Write-AddTypeStep -Status FAIL -Phase 'smoke-yt-dpi-engines (same process)' -Detail '`$? = false'
        throw 'smoke-yt-dpi-engines failed after Add-Type.'
    }
    Write-AddTypeStep -Status PASS -Phase 'smoke-yt-dpi-engines (same process)'
} elseif ($SkipSmoke) {
    Write-AddTypeStep -Status SKIP -Phase 'smoke-yt-dpi-engines' -Detail '-SkipSmoke'
}

Write-AddTypeStep -Status PASS -Phase 'release-gate-addtype complete'
