#requires -Version 5.1
<#
.SYNOPSIS
  Compatibility smoke before release: YT-DPI.ps1 AST, embedded TLS/traceroute C#, PS patterns,
  then the same under separate hosts (Windows PowerShell 5.1 x64/WOW64, pwsh).

.NOTES
  NOT full functional/E2E testing — no live scan, proxy UI, traceroute UI, updates workflow, etc.
  Use manual / integration scenarios for that.

.PARAMETER RepoRoot
  Repository root containing YT-DPI.ps1 (default: parent of tools/).

.PARAMETER SkipWow64
  Do not spawn SysWOW64\powershell.exe.

.PARAMETER SkipChildProcesses
  Only current process (fast).

.PARAMETER OnlyBundledPwsh
  When spawning pwsh children: single candidate after sort.

.PARAMETER Quiet
  Fewer decorative banners; step lines [PASS]/[FAIL]/[SKIP] still printed for logs.
#>
param(
    [string]$RepoRoot = (Split-Path -LiteralPath $PSScriptRoot -Parent),
    [switch]$SkipWow64,
    [switch]$SkipChildProcesses,
    [switch]$OnlyBundledPwsh,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$script:GateSummaryLines = New-Object System.Collections.Generic.List[string]
$script:GateLastPhase = 'startup'

function Write-GateStep {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail = ''
    )
    $script:GateLastPhase = $Phase
    $line = '[{0}] {1}' -f $Status, $Phase
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $line += (' — {0}' -f $Detail)
    }
    [void]$script:GateSummaryLines.Add($line)

    $color = switch ($Status) {
        'PASS' { if ($Quiet) { 'Gray' } else { 'Green' }; break }
        'FAIL' { 'Red'; break }
        default { 'DarkGray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-GateMsg([string]$Msg, [string]$Color = '') {
    if ($Quiet) { return }
    if ($Color) {
        Write-Host $Msg -ForegroundColor $Color
    } else {
        Write-Host $Msg
    }
}

function Format-GateParseErrors {
    param([System.Management.Automation.Language.ParseError[]]$Errors, [string]$Path)
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $Errors) {
        $ln = $e.Extent.StartLineNumber
        $col = $e.Extent.StartColumnNumber
        [void]$sb.AppendLine(('{0}: line {1} col {2}: {3}' -f $Path, $ln, $col, $e.Message))
        $snippet = [string]$e.Extent.Text
        if (-not [string]::IsNullOrWhiteSpace($snippet)) {
            $oneLine = ($snippet -replace '[\r\n]+', ' ').Trim()
            if ($oneLine.Length -gt 200) { $oneLine = $oneLine.Substring(0, 197) + '...' }
            [void]$sb.AppendLine(('      snippet: {0}' -f $oneLine))
        }
    }
    return $sb.ToString().TrimEnd()
}

function Test-YtDpiAstOrThrow {
    param([string]$Path)
    $tokens = $null
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        $formatted = Format-GateParseErrors -Errors @($errs) -Path $Path
        Write-GateStep -Status FAIL -Phase 'AST parse' -Detail ('{0} error(s)' -f $errs.Count)
        Write-Host $formatted -ForegroundColor Red
        throw 'AST parse failed (see diagnostics above).'
    }
    Write-GateStep -Status PASS -Phase 'AST parse' -Detail $Path
}

try {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -match 'Windows') {
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        } catch { }
    }
} catch { }

function Write-GateHostContext {
    param([string]$Label)
    Write-GateMsg "======== $Label ========"
    try {
        $os = [System.Environment]::OSVersion.VersionString
        $ver = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        if ($ver) { Write-GateMsg "OS: $ver" }
        Write-GateMsg "OSVersion: $os"
    } catch {
        Write-GateMsg 'OSVersion: (unavailable)'
    }
    $ed = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
    Write-GateMsg "PSVersion: $($PSVersionTable.PSVersion) | PSEdition: $ed | PID: $PID"
    try {
        $clr = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        Write-GateMsg "Runtime: $clr"
    } catch {
        try {
            Write-GateMsg "CLR: $([System.Environment]::Version)"
        } catch { }
    }
    Write-GateMsg "RepoRoot: $RepoRoot"
    Write-GateMsg '========================'
}

function Get-YtDpiHereStringContent {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory)][regex]$StartPattern
    )
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($StartPattern.IsMatch($Lines[$i])) {
            $sb = New-Object System.Text.StringBuilder
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].Trim() -eq '"@') {
                    return $sb.ToString()
                }
                [void]$sb.AppendLine($Lines[$j])
            }
            throw "Here-string starting at line $($i+1) (pattern $($StartPattern)) not closed with line `"@."
        }
    }
    throw "Here-string start line not found (pattern $($StartPattern))."
}

function Assert-YtDpiSnippetSanity {
    param([string]$TlsCode)
    if ([string]::IsNullOrWhiteSpace($TlsCode)) { throw 'Extracted TLS snippet is empty.' }
    if ($TlsCode -notmatch '(?m)\bclass\s+TlsScanner\b') { throw 'TLS snippet sanity: missing type TlsScanner.' }
}

function Get-PwshCandidatePaths {
    param([switch]$SingleBundled)

    $seen = @{}
    $list = New-Object System.Collections.Generic.List[string]

    function Add-Exe([string]$p) {
        if (-not $p) { return }
        try { $full = [System.IO.Path]::GetFullPath($p) } catch { return }
        if (-not (Test-Path -LiteralPath $full)) { return }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        [void]$seen.Add($key, $true)
        [void]$list.Add($full)
    }

    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { Add-Exe $cmd.Source }

    if (-not $SingleBundled) {
        $pf86 = ${env:ProgramFiles(x86)}
        foreach ($base in @($env:ProgramFiles, $pf86)) {
            if (-not $base) { continue }
            $pwRoot = Join-Path $base 'PowerShell'
            if (-not (Test-Path -LiteralPath $pwRoot)) { continue }
            Get-ChildItem -LiteralPath $pwRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Add-Exe (Join-Path $_.FullName 'pwsh.exe')
            }
        }

        Add-Exe (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
        Add-Exe (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe')
        if ($pf86) {
            Add-Exe (Join-Path $pf86 'PowerShell\7\pwsh.exe')
        }

        $extra = [System.Environment]::GetEnvironmentVariable('YT_DPI_GATE_EXTRA_PS', 'Process')
        if (-not $extra) { $extra = [System.Environment]::GetEnvironmentVariable('YT_DPI_GATE_EXTRA_PS', 'User') }
        if (-not $extra) { $extra = [System.Environment]::GetEnvironmentVariable('YT_DPI_GATE_EXTRA_PS', 'Machine') }
        if ($extra) {
            foreach ($part in $extra -split '[;|]', [System.StringSplitOptions]::RemoveEmptyEntries) {
                Add-Exe $part.Trim()
            }
        }
    }

    $arr = @($list.ToArray())
    $sorted = $arr | Sort-Object `
        @{ Expression = { try { [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_).FileVersion } catch { '0.0.0' } }; Descending = $true },
        @{ Expression = { $_ }; Ascending = $true }
    return [string[]]@($sorted)
}

function Invoke-GateHost {
    param(
        [string]$Exe,
        [string]$Label,
        [string]$TlsFile,
        [string]$Helper,
        [string]$RepoRootArg,
        [string]$LogDir,
        [string]$TraceFile = $null
    )
    Write-GateMsg "---- $Label ----"
    $slugRaw = ($Label -replace '[<>:"/\\|?*\[\]]', '_' -replace '\s+', '_')
    if ([string]::IsNullOrWhiteSpace($slugRaw)) { $slugRaw = 'gate' }
    if ($slugRaw.Length -gt 96) { $slugRaw = $slugRaw.Substring(0, 96) }
    $slug = $slugRaw
    $outLog = Join-Path $LogDir ("gate_{0}_stdout.txt" -f $slug)
    $errLog = Join-Path $LogDir ("gate_{0}_stderr.txt" -f $slug)
    $hostArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper,
        '-TlsPath', $TlsFile
    )
    if ($TraceFile) {
        $hostArgs += @('-TracePath', $TraceFile)
    }
    if ($RepoRootArg) {
        $hostArgs += @('-RepoRoot', $RepoRootArg)
    }
    if ($Quiet) {
        $hostArgs += '-Quiet'
    }
    try {
        Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue
    } catch { }

    $p = Start-Process -FilePath $Exe -ArgumentList $hostArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    if ($p.ExitCode -ne 0) {
        Write-GateStep -Status FAIL -Phase ('child host: {0}' -f $Label) -Detail ('exe={0} exit={1}' -f $Exe, $p.ExitCode)
        Write-Host ('[FAIL] stdout log: {0}' -f $outLog) -ForegroundColor Red
        Write-Host ('[FAIL] stderr log: {0}' -f $errLog) -ForegroundColor Red
        foreach ($pair in @(@('stdout', $outLog), @('stderr', $errLog))) {
            $kind = $pair[0]; $path = $pair[1]
            if (Test-Path -LiteralPath $path) {
                $blob = [System.IO.File]::ReadAllText($path)
                if (-not [string]::IsNullOrWhiteSpace($blob)) {
                    Write-GateMsg "----- tail $kind -----"
                    $lines = $blob -split "`r?`n"
                    $take = [Math]::Min(80, $lines.Count)
                    ($lines | Select-Object -Last $take) | ForEach-Object { Write-GateMsg $_ }
                }
            }
        }
        throw "$Label failed (exe=$Exe exit=$($p.ExitCode))"
    }
    Write-GateStep -Status PASS -Phase ('child host: {0}' -f $Label) -Detail ('exe={0}' -f $Exe)
}

$gateSw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not $Quiet) {
    Write-GateHostContext 'release-gate (orchestrator)'
} else {
    Write-GateStep -Status PASS -Phase 'orchestrator (quiet)' -Detail ("PS $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)")
}

$ytDpi = Join-Path $RepoRoot 'YT-DPI.ps1'
if (-not (Test-Path -LiteralPath $ytDpi)) {
    Write-GateStep -Status FAIL -Phase 'resolve YT-DPI.ps1' -Detail $ytDpi
    throw "YT-DPI.ps1 not found: $ytDpi"
}
Write-GateStep -Status PASS -Phase 'resolve YT-DPI.ps1' -Detail $ytDpi

Test-YtDpiAstOrThrow -Path $ytDpi

$lines = Get-Content -LiteralPath $ytDpi
try {
    $tlsCode = Get-YtDpiHereStringContent -Lines $lines -StartPattern '^\s*\$tlsCode\s*=\s*@"\s*$'
    Write-GateStep -Status PASS -Phase 'extract embedded C# here-strings' -Detail 'TlsScanner only (Deep Trace removed)'
} catch {
    Write-GateStep -Status FAIL -Phase 'extract embedded C# here-strings' -Detail "$_"
    throw
}

try {
    Assert-YtDpiSnippetSanity -TlsCode $tlsCode
    Write-GateStep -Status PASS -Phase 'snippet sanity (TlsScanner)'
} catch {
    Write-GateStep -Status FAIL -Phase 'snippet sanity' -Detail "$_"
    throw
}

$dir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('yt-dpi-release-gate-{0}' -f [guid]::NewGuid().ToString('N')))
$null = New-Item -ItemType Directory -Path $dir -Force
$gateSucceeded = $false
try {
    $tlsFile = Join-Path $dir 'tls_gate.cs.txt'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tlsFile, $tlsCode, $utf8)
    Write-GateStep -Status PASS -Phase 'write temp snippet files' -Detail $dir

    $helper = Join-Path $PSScriptRoot 'release-gate-addtype.ps1'
    if (-not (Test-Path -LiteralPath $helper)) {
        Write-GateStep -Status FAIL -Phase 'resolve release-gate-addtype.ps1'
        throw "Missing $helper"
    }

    $smoke = Join-Path $PSScriptRoot 'smoke-yt-dpi-engines.ps1'
    $smokeSplat = @{ RepoRoot = $RepoRoot }
    if ($Quiet) { $smokeSplat['Quiet'] = $true }

    if (Test-Path -LiteralPath $smoke) {
        Write-GateMsg '---- smoke-yt-dpi-engines (current host, before Add-Type) ----'
        try {
            & $smoke @smokeSplat
            if (-not $?) { throw 'smoke exited with error flag.' }
            Write-GateStep -Status PASS -Phase 'smoke-yt-dpi-engines (pre Add-Type)'
        } catch {
            Write-GateStep -Status FAIL -Phase 'smoke-yt-dpi-engines (pre Add-Type)' -Detail "$_"
            throw
        }
    }

    Write-GateMsg '---- Add-Type + smoke (current session) ----'
    $addArgs = @{
        TlsPath   = $tlsFile
        RepoRoot  = $RepoRoot
        SkipSmoke = $false
    }
    if ($Quiet) { $addArgs['Quiet'] = $true }
    try {
        & $helper @addArgs
        if (-not $?) {
            throw ('release-gate-addtype reported failure ($?={0}; LASTEXITCODE={1}).' -f $?, $LASTEXITCODE)
        }
        Write-GateStep -Status PASS -Phase 'release-gate-addtype (orchestrator session)'
    } catch {
        Write-GateStep -Status FAIL -Phase 'release-gate-addtype (orchestrator session)' -Detail "$_"
        Write-Host ('[FAIL] TlsPath={0}' -f $tlsFile) -ForegroundColor Red
        throw
    }

    if (-not $SkipChildProcesses) {
        $winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $winPs) {
            Invoke-GateHost -Exe $winPs -Label 'Windows PowerShell 5.1 x64 (System32)' `
                -TlsFile $tlsFile -Helper $helper -RepoRootArg $RepoRoot -LogDir $dir
        } else {
            Write-Warning 'powershell.exe not found under System32; skipped.'
            Write-GateStep -Status SKIP -Phase 'Windows PowerShell 5.1 x64' -Detail 'powershell.exe missing under System32'
        }

        if (-not $SkipWow64) {
            $wowPs = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $wowPs) {
                Invoke-GateHost -Exe $wowPs -Label 'Windows PowerShell 5.1 WOW64 (32-bit)' `
                    -TlsFile $tlsFile -Helper $helper -RepoRootArg $RepoRoot -LogDir $dir
            } else {
                Write-GateMsg '---- WOW64 powershell.exe not present (e.g. ARM64 host); skip ----'
                Write-GateStep -Status SKIP -Phase 'Windows PowerShell 5.1 WOW64' -Detail 'exe not present'
            }
        } else {
            Write-GateStep -Status SKIP -Phase 'Windows PowerShell 5.1 WOW64' -Detail '-SkipWow64'
        }

        $pwshList = @(Get-PwshCandidatePaths -SingleBundled:$OnlyBundledPwsh)
        if ($OnlyBundledPwsh -and $pwshList.Count -gt 1) {
            $pwshList = @($pwshList[0])
            Write-GateMsg ("---- OnlyBundledPwsh: using first candidate after sort: {0} ----" -f $pwshList[0])
        }

        if ($pwshList.Count -eq 0) {
            Write-Warning 'No pwsh.exe candidates found; install PowerShell 7+ or set YT_DPI_GATE_EXTRA_PS.'
            Write-GateStep -Status SKIP -Phase 'pwsh matrix' -Detail 'no pwsh.exe candidates'
        } else {
            $n = 0
            foreach ($exe in $pwshList) {
                $n++
                Invoke-GateHost -Exe $exe -Label ("pwsh candidate {0} / {1}: {2}" -f $n, $pwshList.Count, $exe) `
                    -TlsFile $tlsFile -Helper $helper -RepoRootArg $RepoRoot -LogDir $dir
            }
        }
    } else {
        Write-GateStep -Status SKIP -Phase 'child processes' -Detail '-SkipChildProcesses'
        Write-GateMsg '---- Child processes: skipped (-SkipChildProcesses) ----' 'Yellow'
    }

    $gateSucceeded = $true
    $gateSw.Stop()
    Write-GateMsg ''
    Write-GateMsg '=== SUMMARY ==='
    foreach ($s in $script:GateSummaryLines) {
        Write-Host $s
    }
    Write-GateMsg ('RELEASE GATE: ALL OK ({0:N1} s total)' -f $gateSw.Elapsed.TotalSeconds) 'Green'
} catch {
    $gateSw.Stop()
    Write-GateStep -Status FAIL -Phase 'release gate' -Detail ('last phase: {0}' -f $script:GateLastPhase)
    Write-GateMsg ("Artifacts kept for debugging: {0}" -f $dir) 'Yellow'
    Write-GateMsg ''
    Write-GateMsg '=== SUMMARY (partial) ==='
    foreach ($s in $script:GateSummaryLines) {
        Write-Host $s
    }
    throw
} finally {
    if ($gateSw.IsRunning) { $gateSw.Stop() }
    $keep = [string]::Equals([Environment]::GetEnvironmentVariable('YT_DPI_GATE_KEEP_TEMP'), '1', [System.StringComparison]::OrdinalIgnoreCase)
    if ($gateSucceeded -and -not $keep) {
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    } elseif ($gateSucceeded -and $keep) {
        Write-GateMsg ('YT_DPI_GATE_KEEP_TEMP=1 - temp dir preserved: {0}' -f $dir) 'Cyan'
    }
}
