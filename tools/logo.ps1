# Reads YT-DPI-LOGO-BEGIN ... YT-DPI-LOGO-END from YT-DPI.ps1 and draws the same logo centered.
param(
    [string] $SourceScript,
    [switch] $NoReadKey
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-YtDpiMainScriptPath {
    param([string] $Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) {
        return (Resolve-Path -LiteralPath $Explicit).ProviderPath
    }
    $startDirs = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        [void]$startDirs.Add((Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath)
    }
    try {
        $loc = (Get-Location).ProviderPath
        if ($loc -and $startDirs -notcontains $loc) { [void]$startDirs.Add($loc) }
    } catch { }

    foreach ($start in $startDirs) {
        $dir = $start
        while ($dir) {
            $candidate = Join-Path $dir 'YT-DPI.ps1'
            if (Test-Path -LiteralPath $candidate) {
                return (Resolve-Path -LiteralPath $candidate).ProviderPath
            }
            $parent = Split-Path -Path $dir -Parent
            if (-not $parent -or ($parent -eq $dir)) { break }
            $dir = $parent
        }
    }
    return $null
}

function Get-ConsoleViewSize {
    $cw = 0
    $ch = 0
    try {
        $raw = $Host.UI.RawUI
        $cw = [int]$raw.WindowSize.Width
        $ch = [int]$raw.WindowSize.Height
    } catch { }
    if ($cw -lt 40) {
        try { $cw = [Console]::WindowWidth } catch { $cw = 120 }
    }
    if ($ch -lt 10) {
        try { $ch = [Console]::WindowHeight } catch { $ch = 30 }
    }
    if ($cw -lt 40) { $cw = 120 }
    if ($ch -lt 10) { $ch = 30 }
    return [PSCustomObject]@{ W = $cw; H = $ch }
}

function Out-Str([int] $x, [int] $y, [string] $str, [string] $color = 'White', [string] $bg = 'Black') {
    try {
        [Console]::CursorVisible = $false
        [Console]::SetCursorPosition($x, $y)
        [Console]::ForegroundColor = $color
        [Console]::BackgroundColor = $bg
        [Console]::Write($str)
        [Console]::BackgroundColor = 'Black'
    } catch { }
}

$explicitPath = if ($PSBoundParameters.ContainsKey('SourceScript')) { $SourceScript } else { $null }
$SourceScript = Get-YtDpiMainScriptPath -Explicit $explicitPath
if (-not $SourceScript) {
    $hint = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        'PSScriptRoot пуст (скрипт мог быть запущен не через -File). Запускайте: pwsh -File tools\logo.ps1 или укажите -SourceScript путь\YT-DPI.ps1'
    } else {
        "Обошли каталоги от $PSScriptRoot и текущей папки вверх — YT-DPI.ps1 не найден. Укажите -SourceScript."
    }
    Write-Error $hint
    exit 1
}

if (-not (Test-Path -LiteralPath $SourceScript)) {
    Write-Error "Source script not found: $SourceScript"
    exit 1
}

$begin = (Select-String -LiteralPath $SourceScript -SimpleMatch 'YT-DPI-LOGO-BEGIN' | Select-Object -First 1).LineNumber
$end = (Select-String -LiteralPath $SourceScript -SimpleMatch 'YT-DPI-LOGO-END' | Select-Object -First 1).LineNumber
if (-not $begin -or -not $end -or $end -le $begin) {
    Write-Error "Markers YT-DPI-LOGO-BEGIN / YT-DPI-LOGO-END missing or invalid order in: $SourceScript"
    exit 1
}

# LineNumber is 1-based; first line after BEGIN is at index $begin in Get-Content (0-based) array
$lines = Get-Content -LiteralPath $SourceScript -Encoding UTF8
$slice = $lines[$begin..($end - 2)]
$rx = [regex] '^\s*Out-Str\s+(\d+)\s+(\d+)\s+''(.+?)''\s+''(\w+)''\s*(?:#.*)?$'
$calls = foreach ($line in $slice) {
    $m = $rx.Match($line)
    if (-not $m.Success) { continue }
    [pscustomobject]@{
        X     = [int] $m.Groups[1].Value
        Y     = [int] $m.Groups[2].Value
        Text  = $m.Groups[3].Value.Replace("''", "'")
        Color = $m.Groups[4].Value
    }
}
if (@($calls).Count -lt 2) {
    Write-Error 'No Out-Str lines parsed between logo markers (format must match YT-DPI.ps1).'
    exit 1
}

$byY = $calls | Group-Object Y | Sort-Object { [int] $_.Name }
$rows = foreach ($g in $byY) {
    $items = @($g.Group | Sort-Object X)
    if ($items.Count -lt 2) {
        Write-Error ('Logo row Y={0}: need two Out-Str calls (left and right).' -f $g.Name)
        exit 1
    }
    [pscustomobject]@{ Left = $items[0]; Right = $items[-1] }
}

$gap = $rows[0].Right.X - $rows[0].Left.X
foreach ($r in $rows) {
    $g = $r.Right.X - $r.Left.X
    if ($g -ne $gap) {
        Write-Error ('Logo: X gap mismatch (expected {0}, got {1}, row Y={2}).' -f $gap, $g, $r.Left.Y)
        exit 1
    }
}

# Visual width: left at col 0, right at col $gap (same relative layout as in YT-DPI.ps1).
$blockW = 0
foreach ($r in $rows) {
    $endCol = [Math]::Max($r.Left.Text.Length, $gap + $r.Right.Text.Length)
    if ($endCol -gt $blockW) { $blockW = $endCol }
}
$blockH = $rows.Count

function Sync-ConsoleBufferToWindow {
    try {
        $raw = $Host.UI.RawUI
        $ws = $raw.WindowSize
        if ($ws.Width -le 0 -or $ws.Height -le 0) { return }
        $bs = $raw.BufferSize
        $needW = [Math]::Max($ws.Width, 1)
        $needH = [Math]::Max($ws.Height, 1)
        # Buffer must be >= window; shrink height to window so content stays in view.
        if ($bs.Width -ne $needW -or $bs.Height -ne $needH) {
            # Grow first if needed (PS requires buffer >= window when shrinking window).
            if ($bs.Width -lt $needW -or $bs.Height -lt $needH) {
                $grow = $bs
                if ($grow.Width -lt $needW) { $grow.Width = $needW }
                if ($grow.Height -lt $needH) { $grow.Height = $needH }
                $raw.BufferSize = $grow
            }
            $bs2 = $raw.BufferSize
            $bs2.Width = $needW
            $bs2.Height = $needH
            $raw.BufferSize = $bs2
        }
        try { $raw.WindowPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0 } catch { }
    } catch { }
}

function Draw-CenteredLogo {
    try {
        [Console]::Title = 'YT-DPI Logo'
        [Console]::CursorVisible = $false
    } catch { }
    Sync-ConsoleBufferToWindow
    try { Clear-Host } catch { }
    $view = Get-ConsoleViewSize
    $ox = [Math]::Max(0, [int][Math]::Floor(($view.W - $blockW) / 2))
    $oy = [Math]::Max(0, [int][Math]::Floor(($view.H - $blockH) / 2))
    $ri = 0
    foreach ($r in $rows) {
        Out-Str $ox ($oy + $ri) $r.Left.Text $r.Left.Color
        Out-Str ($ox + $gap) ($oy + $ri) $r.Right.Text $r.Right.Color
        $ri++
    }
    return $view
}

# First paint (start "" may open before size is final).
Start-Sleep -Milliseconds 50
$view = Draw-CenteredLogo
$lastW = [int]$view.W
$lastH = [int]$view.H

if ($NoReadKey) { exit 0 }

# Keep centered while the window is resized (maximize / restore / drag).
while ($true) {
    if ([Console]::KeyAvailable) {
        try { $null = [Console]::ReadKey($true) } catch { }
        break
    }
    $now = Get-ConsoleViewSize
    if ([int]$now.W -ne $lastW -or [int]$now.H -ne $lastH) {
        # Debounce rapid resize events.
        Start-Sleep -Milliseconds 80
        $now = Get-ConsoleViewSize
        $view = Draw-CenteredLogo
        $lastW = [int]$view.W
        $lastH = [int]$view.H
    } else {
        Start-Sleep -Milliseconds 50
    }
}
