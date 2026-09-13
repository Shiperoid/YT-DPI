$script:OriginalFilePath = [System.Environment]::GetEnvironmentVariable("SCRIPT_PATH", "Process")
if (-not $script:OriginalFilePath) { $script:OriginalFilePath = $MyInvocation.MyCommand.Path }
if (-not $script:OriginalFilePath) { $script:OriginalFilePath = $MyInvocation.InvocationName }

# --- CLI (3.0): парсим до TUI, чтобы --batch работал без интерактива ---
$script:BatchMode = $false
$script:NoExtras = $false
$script:JsonReportPath = $null
$script:TxtReportPath = $null
$script:CliArgs = @($args)
for ($__i = 0; $__i -lt $script:CliArgs.Count; $__i++) {
    $a = [string]$script:CliArgs[$__i]
    switch -Regex ($a) {
        '^--batch$' { $script:BatchMode = $true; continue }
        '^--no-extras$' { $script:NoExtras = $true; continue }
        '^--json$' {
            if ($__i + 1 -lt $script:CliArgs.Count) { $script:JsonReportPath = [string]$script:CliArgs[++$__i] }
            else { $script:JsonReportPath = "" }
            continue
        }
        '^--json=(.+)$' { $script:JsonReportPath = $Matches[1]; continue }
        '^--report$' {
            if ($__i + 1 -lt $script:CliArgs.Count) { $script:TxtReportPath = [string]$script:CliArgs[++$__i] }
            else { $script:TxtReportPath = "" }
            continue
        }
        '^--report=(.+)$' { $script:TxtReportPath = $Matches[1]; continue }
        '^--help$|^-h$' {
            Write-Host "YT-DPI 3.0.1 — usage:"
            Write-Host "  YT-DPI.bat [--batch] [--no-extras] [--json path] [--report path]"
            Write-Host "  --batch       headless suite (scan + extras), write reports, exit 0/1/2"
            Write-Host "  --no-extras   domain scan only (skip QUIC/DNS/TCP16/IpVsSni)"
            Write-Host "  --json path   JSON report (default: YT-DPI_Report.json next to script)"
            Write-Host "  --report path TXT report (default with --batch: YT-DPI_Report.txt)"
            exit 0
        }
    }
}

$ErrorActionPreference = "SilentlyContinue"
$script:CurrentWindowWidth = 0
$script:CurrentWindowHeight = 0
$script:UiLayoutWidth = $null
$script:UiLayoutHeight = $null
if (-not $script:BatchMode) {
    try { [Console]::BufferHeight = [Console]::WindowHeight } catch { }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try { [Console]::CursorVisible = $false } catch { }
    try { [Console]::CursorSize = 1 } catch { }
    try {
        [Console]::ForegroundColor = "Cyan"
        [Console]::WriteLine("[ BOOT ] Loading YT-DPI...")
        [Console]::ResetColor()
    } catch {}
} else {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}
$ErrorActionPreference = "Continue"

$DebugPreference = "SilentlyContinue"

# Безопасно по умолчанию: не отключаем проверку TLS-сертификатов
$script:AllowInsecureTls = $false
if ($script:AllowInsecureTls) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
[System.Net.ServicePointManager]::DefaultConnectionLimit = 100

$scriptVersion = "3.0.1"   # YT-DPI 3.0.1 (Windows)
# ===== ОТЛАДКА =====
$debugEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG", "Process")
if (-not $debugEnvRaw) { $debugEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG", "User") }
if (-not $debugEnvRaw) { $debugEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG", "Machine") }
$DEBUG_ENABLED = [string]$debugEnvRaw -match '^(?i:1|true|yes|on)$'
# В хвосте строки DEBUG в UI: добавить PID (по умолчанию выкл — безопаснее для скриншотов)
$script:DebugHudIncludePid = $false

$forceFreshEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_FORCE_NET_REFRESH", "Process")
if (-not $forceFreshEnvRaw) { $forceFreshEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_FORCE_NET_REFRESH", "User") }
if (-not $forceFreshEnvRaw) { $forceFreshEnvRaw = [System.Environment]::GetEnvironmentVariable("YT_DPI_FORCE_NET_REFRESH", "Machine") }
$script:ForceFreshNetInfo = [string]$forceFreshEnvRaw -match '^(?i:1|true|yes|on)$'
$DebugLogFile = Join-Path (Get-Location).Path "YT-DPI_Debug.log"
# Один mutex на все процессы/потоки, пишущие в YT-DPI_Debug.log (иначе Add-Content/параллельный append даёт сбои).
$script:DebugLogMutexName = "Global\YT-DPI-Debug-Mutex"
$DebugLogMutex = New-Object System.Threading.Mutex($false, $script:DebugLogMutexName)

$SCRIPT:CONST = @{
    TimeoutMs    = 700       # Снижено с 1500
    ProxyTimeout = 1200      # Снижено с 2500
    HttpPort     = 80
    HttpsPort    = 443
    Tls13Proto   = 12288
    AnimFps      = 30
    ScanPoolMinWorkers    = 8
    ScanPoolDirectMax     = 24
    ScanPoolProxyMax      = 12
    ScanPoolCpuMultiplier = 3
    Mutex = @{ WaitMs = 7000 }   # Снижено с 15000
    Scan = @{
        HttpDirectCapMs       = 600    # Снижено с 1200
        TlsFastMsDirect       = 800    # Снижено с 1600
        TlsFastMsProxy        = 1200   # Снижено с 2200
        TlsRetryMsDirect      = 1300   # Снижено с 2600
        TlsRetryMsProxyFloor  = 1300   # Снижено с 2600
    }
    NetInfo = @{
        WebFastDefaultMs      = 1000   # Снижено с 3000
        RedirectorMs          = 700    # Снижено с 2000
        GeoPerRequestMs       = 500    # Снижено с 1500
        Ipv6ProbeWaitMs       = 350    # Снижено с 1000
        RedirectorRequestMs   = 700    # Снижено с 3000
    }
    ProxySelfTest = @{
        DetectTcpConnectMs = 700     # Снижено с 2000
        DetectStreamRwMs   = 800     # Снижено с 2000
        QuickTunnelMs      = 2000    # Снижено с 5000
        TcpToProxyMs       = 1500    # Снижено с 4000
        Tunnel443Ms        = 2000    # Снижено с 7000
        HttpGstaticMs      = 1300    # Снижено с 5000
        HttpSlowWarnMs     = 1500    # Снижено с 4800
        PauseAfterTcpMs    = 60      # Снижено с 120
        PauseAfterTunnelMs = 60      # Снижено с 150
        PauseAfterHttpMs   = 80      # Снижено с 200
    }
    UiScan = @{
        StatusBarThrottleCollectMs = 90   # Снижено с 240
        StatusBarThrottleRevealMs  = 110  # Снижено с 280
        RevealAnimFps            = 48
        ResizeDebounceMs         = 180
    }
    Internet = @{
        PingTimeoutMs    = 400    # Снижено с 1000
        TcpFallbackMs    = 400    # Снижено с 1000
    }
    HttpMisc = @{
        GitHubReleaseApiMs      = 1500   # Снижено с 5000
        RedirectorViaProxyMs    = 1200   # Снижено с 3000
        GeoProviderViaProxyMs   = 500    # Снижено с 1500
    }
    Quic = @{
        TimeoutMs     = 1200
        ControlHost   = "cloudflare.com"
        TargetHost    = "youtube.com"
        Port          = 443
    }
    DnsProbe = @{
        TimeoutMs = 1500
        Hosts     = @("youtube.com", "googlevideo.com", "i.ytimg.com")
        DohUrls   = @(
            "https://cloudflare-dns.com/dns-query",
            "https://dns.google/resolve"
        )
    }
    Tcp16 = @{
        BytesTarget   = 32768
        DropMinBytes  = 12288
        DropMaxBytes  = 24576
        TimeoutMs     = 4000
        HostFallback  = "googlevideo.com"
    }
    IpVsSni = @{
        YoutubeSni = "www.youtube.com"
        ControlSni = "ya.ru"
        TimeoutMs  = 1500
    }
    Batch = @{
        DefaultJsonName = "YT-DPI_Report.json"
        DefaultTxtName  = "YT-DPI_Report.txt"
    }
    BypassProcessNames = @(
        "winws", "goodbyedpi", "GoodbyeDPI", "zapret", "zapret2",
        "byedpi", "ByeDPI", "ciadpi", "blockcheck", "WinDivert"
    )
    Graph = @{
        DefaultWidth   = 10
        LatBarWidth    = 6
        PathMaxHops    = 15
        PathSamples    = 3
        PathIntervalMs = 200
        PathTimeoutMs  = 1000
    }
    UI = @{
        Num = 1; Dom = 6; IP = 50; HTTP = 68; T12 = 76; T13 = 86; Lat = 96; Ver = 110
    }
    NavStr = "[READY] [ENTER] SCAN | [S] SETTINGS | [P] PROXY | [D] DNS | [G] PATH | [E] EXTRA | [U] UPDATE | [R] REPORT | [H] HELP | [Q] QUIT"
}
$CONST = $SCRIPT:CONST

$script:ExtraDiag = [ordered]@{
    BypassTools = @{ Detected = $false; Names = @() }
    Dns = @()
    Quic = $null
    Tcp16 = $null
    IpVsSni = $null
    RstStats = @{ RstCh = 0; RstPost = 0 }
    Recommendations = @()
}
$script:ParentDirForReports = Split-Path -Parent $script:OriginalFilePath
if (-not $script:ParentDirForReports) { $script:ParentDirForReports = (Get-Location).Path }
if ($null -eq $script:JsonReportPath) { $script:JsonReportPath = $null }
elseif ($script:JsonReportPath -eq "") { $script:JsonReportPath = Join-Path $script:ParentDirForReports $CONST.Batch.DefaultJsonName }
if ($null -eq $script:TxtReportPath) { $script:TxtReportPath = $null }
elseif ($script:TxtReportPath -eq "") { $script:TxtReportPath = Join-Path $script:ParentDirForReports $CONST.Batch.DefaultTxtName }
if ($script:BatchMode -and -not $script:JsonReportPath) {
    $script:JsonReportPath = Join-Path $script:ParentDirForReports $CONST.Batch.DefaultJsonName
}
if ($script:BatchMode -and -not $script:TxtReportPath) {
    $script:TxtReportPath = Join-Path $script:ParentDirForReports $CONST.Batch.DefaultTxtName
}

# ===== ЛОГИРОВАНИЕ И РОТАЦИЯ =====
$maxLogSizeBytes = 5 * 1024 * 1024
if (Test-Path $DebugLogFile) {
    try {
        $fileInfo = Get-Item $DebugLogFile
        if ($fileInfo.Length -gt $maxLogSizeBytes) {
            $backupName = [System.IO.Path]::GetFileNameWithoutExtension($DebugLogFile) + "_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".log"
            Move-Item $DebugLogFile (Join-Path (Split-Path $DebugLogFile -Parent) $backupName) -Force
        } else {
            Remove-Item $DebugLogFile -Force -ErrorAction SilentlyContinue
        }
    } catch { Remove-Item $DebugLogFile -Force -ErrorAction SilentlyContinue }
}

function Test-DebugLogEnabled {
    if ($DEBUG_ENABLED) { return $true }
    try {
        if ($script:Config -and ($script:Config.DebugLogEnabled -eq $true)) { return $true }
    } catch { }
    return $false
}

# Полные ПК/пользователь/пути в заголовке лога — только при явном согласии (конфиг или YT_DPI_DEBUG_IDENTIFIERS).
function Test-DebugLogWriteFullIdentifiers {
    $raw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG_IDENTIFIERS", "Process")
    if (-not $raw) { $raw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG_IDENTIFIERS", "User") }
    if (-not $raw) { $raw = [System.Environment]::GetEnvironmentVariable("YT_DPI_DEBUG_IDENTIFIERS", "Machine") }
    if ([string]$raw -match '^(?i:1|true|yes|on)$') { return $true }
    try {
        if ($script:Config -and ($script:Config.DebugLogFullIdentifiers -eq $true)) { return $true }
    } catch { }
    return $false
}

function Get-DebugHudTail {
    param([int]$maxLen = 0)

    # Определяем редакцию (Core / Desktop) и версию PowerShell
    $edition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
    $version = $PSVersionTable.PSVersion.ToString()  # например "7.6.2" или "5.1.19041.1"
    $editionVersion = "$edition $version"

    # Проверка прав администратора
    try {
        $isAdm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdm = $false }
    $au = if ($isAdm) { 'Adm' } else { 'Usr' }

    # IpPreference из конфига
    $ipPref = '?'
    try { if ($script:Config -and $script:Config.IpPreference) { $ipPref = [string]$script:Config.IpPreference } } catch { }

    # TlsMode из конфига
    $tls = 'Auto'
    try { if ($script:Config -and $script:Config.TlsMode) { $tls = [string]$script:Config.TlsMode } } catch { }

    # Прокси
    $px = if ($global:ProxyConfig -and $global:ProxyConfig.Enabled) { 'Px1' } else { 'Px0' }

    # Размер окна консоли
    try {
        $ww = [Console]::WindowWidth
        $wh = [Console]::WindowHeight
    } catch { $ww = 0; $wh = 0 }

    # Собираем базовую строку (теперь с редакцией и версией)
    $base = " ${editionVersion} ${au} ${ipPref} ${tls} ${px} ${ww}x${wh}"

    # Добавляем PID, если требуется
    if ($script:DebugHudIncludePid) { $base = "PID=$PID $base" }

    # Обрезаем до максимальной длины, если нужно
    if ($maxLen -gt 0 -and $base.Length -gt $maxLen) { return $base.Substring(0, $maxLen) }
    return $base
}

function Write-DebugLog($msg, $level = "DEBUG") {
    if (-not (Test-DebugLogEnabled)) { return }
    $line = "[$(Get-Date -Format 'HH:mm:ss.fff')] [$level] $msg`r`n"
    $got = $false
    try {
        try { $got = $DebugLogMutex.WaitOne([int]$CONST.Mutex.WaitMs) } catch { $got = $false }
        if (-not $got) { return }
        [System.IO.File]::AppendAllText($DebugLogFile, $line, [System.Text.Encoding]::UTF8)
    } catch { }
    finally {
        if ($got) {
            try { [void]$DebugLogMutex.ReleaseMutex() } catch { }
        }
    }
}

# Данные для заголовка лога: собираем всегда (раньше только при YT_DPI_DEBUG — в логе из конфига были «заглушки»)
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }
try { $osInfo = Get-CimInstance Win32_OperatingSystem } catch { $osInfo = @{ Caption = "Windows (Legacy)"; Version = "Unknown" } }

$script:DebugSessionHeaderWritten = $false

function Write-DebugLogSessionHeaderIfNeeded {
    if (-not (Test-DebugLogEnabled)) { return }
    if ($script:DebugSessionHeaderWritten) { return }
    $script:DebugSessionHeaderWritten = $true

    Write-DebugLog "==================== YT-DPI SESSION START ====================" "INFO"
    Write-DebugLog "Скрипт версия: $scriptVersion" "INFO"
    Write-DebugLog "ОС: $($osInfo.Caption) ($($osInfo.Version))" "INFO"
    Write-DebugLog "PowerShell: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion) | PID: $PID" "INFO"
    Write-DebugLog "Права: $(if ($isAdmin) { 'Администратор' } else { 'Пользователь' })" "INFO"
    if (Test-DebugLogWriteFullIdentifiers) {
        Write-DebugLog "Компьютер: $env:COMPUTERNAME | Пользователь Windows: $env:USERNAME | Домен/рабочая группа: $env:USERDOMAIN" "INFO"
    } else {
        Write-DebugLog "Узел/пользователь Windows: [обезличено] (полные данные: п.5 в настройках или YT_DPI_DEBUG_IDENTIFIERS=1)" "INFO"
    }
    Write-DebugLog "Локаль: $([System.Globalization.CultureInfo]::CurrentCulture.Name)" "INFO"
    try {
        Write-DebugLog "Архитектура: OS 64-bit=$([System.Environment]::Is64BitOperatingSystem), процесс PowerShell 64-bit=$([System.Environment]::Is64BitProcess)" "INFO"
    } catch { }

    # ---------- НОВЫЙ БЛОК: статус загрузки целей ----------
    if (Get-Variable -Name BaseTargets -Scope Script -ErrorAction SilentlyContinue) {
        $targetsCount = $BaseTargets.Count
        if ($script:CustomTargetsLoaded) {
            Write-DebugLog "Список целей: загружен из кастомного файла ($targetsCount шт.)" "INFO"
        } else {
            Write-DebugLog "Список целей: используется встроенный список ($targetsCount шт.)" "INFO"
            if (Get-Variable -Name NetInfo -Scope Script -ErrorAction SilentlyContinue) {
                if ($NetInfo.CDN -and $NetInfo.CDN -notin $BaseTargets) {
                    Write-DebugLog "Примечание: встроенный список будет дополнен CDN-адресом: $($NetInfo.CDN)" "INFO"
                }
            }
        }
    } else {
        Write-DebugLog "Список целей: не определён (переменная BaseTargets не найдена)" "WARN"
    }
    # -------------------------------------------------------

    if (Test-DebugLogWriteFullIdentifiers) {
        Write-DebugLog "Путь к скрипту: $script:OriginalFilePath" "INFO"
        Write-DebugLog "Рабочая папка: $((Get-Location).Path)" "INFO"
        Write-DebugLog "Лог-файл: $DebugLogFile | YT_DPI_DEBUG (env): $DEBUG_ENABLED | DebugLogEnabled (config): $(if ($script:Config -and $script:Config.DebugLogEnabled) { $true } else { $false })" "INFO"
    } else {
        $scriptLeaf = if ($script:OriginalFilePath) { [System.IO.Path]::GetFileName($script:OriginalFilePath) } else { '?' }
        Write-DebugLog "Путь к скрипту: [обезличено] (только имя файла: $scriptLeaf)" "INFO"
        Write-DebugLog "Рабочая папка: [обезличено]" "INFO"
        Write-DebugLog "Лог-файл: YT-DPI_Debug.log (рядом со скриптом, полный путь скрыт) | YT_DPI_DEBUG (env): $DEBUG_ENABLED | DebugLogEnabled (config): $(if ($script:Config -and $script:Config.DebugLogEnabled) { $true } else { $false })" "INFO"
    }
    Write-DebugLog "============================================================" "INFO"
    if ($DEBUG_ENABLED) {
        Write-DebugLog "Лог при старте очищался/ротировался по правилам env YT_DPI_DEBUG." "INFO"
    } else {
        Write-DebugLog "Запись лога включена без очистки файла при старте (только конфиг или env без предочистки)." "INFO"
    }
}

# Заголовок сессии пишем после финального пути к логу и Load-Config (см. Initialize-AppState)
# --- ОТКЛЮЧЕНИЕ ВЫДЕЛЕНИЯ МЫШЬЮ ---
Write-DebugLog "Отключаем QuickEdit..."
$code = @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    const uint ENABLE_QUICK_EDIT = 0x0040;
    const int STD_INPUT_HANDLE = -10;
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll")]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    public static void DisableQuickEdit() {
        IntPtr consoleHandle = GetStdHandle(STD_INPUT_HANDLE);
        uint consoleMode;
        if (GetConsoleMode(consoleHandle, out consoleMode)) {
            consoleMode &= ~ENABLE_QUICK_EDIT;
            SetConsoleMode(consoleHandle, consoleMode);
        }
    }
}
"@
function Initialize-ConsoleHelper {
    if (-not ([System.Management.Automation.PSTypeName]'ConsoleHelper').Type) {
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
    if (([System.Management.Automation.PSTypeName]'ConsoleHelper').Type) {
        [ConsoleHelper]::DisableQuickEdit()
        Write-DebugLog "QuickEdit отключён." "INFO"
    }
}
Initialize-ConsoleHelper

# --- ГЛОБАЛЬНЫЕ НАСТРОЙКИ ---
$global:ProxyConfig = @{ Enabled = $false; Type = "HTTP"; Host = ""; Port = 0; User = ""; Pass = "" }
$script:DnsCache = @{}
$script:DnsCacheLock = New-Object System.Threading.Mutex($false, "Global\YT-DPI-DNS-Cache")
$script:NetInfo = $null
$script:Targets = $null
$script:LastScanResults = @()
$script:DynamicColPos = $null
$script:IpColumnWidth = 16
$script:UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --- ИНИЦИАЛИЗАЦИЯ ПЕРЕМЕННЫХ ОКРУЖЕНИЯ ---
$script:Config = $null
$script:NetInfo = $null
$script:DnsCache = [hashtable]::Synchronized(@{}) # Сразу делаем его потокобезопасным
$script:LastScanResults = @()
# Уже был хотя бы один завершённый скан (для частичного «водопада» и отключения idle-арта)
$script:HasCompletedScan = $false
# Idle | Running | Finishing — guard against double Enter / mid-scan redraw races
$script:ScanPhase = "Idle"
# 0 = none / idle; interactive EXTRA uses ExtrasPending + async PS (not step 1..N)
$script:ExtrasStep = 0
$script:ExtrasPending = $false
$script:ExtrasPs = $null
$script:ExtrasHandle = $null
$script:ExtrasRunspace = $null
# Shared scan RunspacePool (reused across Enter scans)
$script:ScanRunspacePool = $null
$script:ScanRunspacePoolMax = 0
$script:ScanRunspacePoolForceRecreate = $false
# Table viewport scroll (large targets.txt)
$script:TableScrollOffset = 0
# Non-scroll key drained while coalescing arrow-key flood
$script:PendingMainKey = $null
$script:StatusFeedbackCacheKey = $null
$script:StatusControlsCacheKey = $null
$script:StatusBarLayoutW = $null
$script:ResizePendingSince = $null
$script:ResizePendingW = $null
$script:ResizePendingH = $null
$script:BypassWarnShownThisSession = $false

# Фоновая задача для предзагрузки NetInfo
$script:BackgroundNetInfo = $null
$script:NetInfoUpdating = $false

function Start-BackgroundNetInfoUpdate {
    if ($script:NetInfoUpdating) { return }
    $script:NetInfoUpdating = $true

    $existing = Get-Job -Name "NetInfoUpdater" -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-Job $existing -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $existing -Force -ErrorAction SilentlyContinue } catch {}
    }

    Start-Job -Name "NetInfoUpdater" -ScriptBlock {
        function Invoke-WebRequestFast($url, $timeout = 3000) {
            try {
                $req = [System.Net.WebRequest]::Create($url)
                $req.Timeout = $timeout
                $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
                $resp = $req.GetResponse()
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $content = $reader.ReadToEnd()
                $resp.Close()
                return $content
            } catch { return "" }
        }

        $result = @{
            DNS = "UNKNOWN"
            CDN = "manifest.googlevideo.com"
            ISP = "Loading..."
            LOC = "Unknown"
            HasIPv6 = $false
        }

        # DNS (WMI, then DnsClient)
        try {
            $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                   Where-Object { $_.DNSServerSearchOrder -ne $null -and @($_.DNSServerSearchOrder).Count -gt 0 } |
                   Select-Object -First 1
            if ($wmi) { $result.DNS = [string](@($wmi.DNSServerSearchOrder)[0]) }
        } catch {}
        if ($result.DNS -eq "UNKNOWN") {
            try {
                $row = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.ServerAddresses -and @($_.ServerAddresses).Count -gt 0 } |
                    Select-Object -First 1
                if ($row) { $result.DNS = [string](@($row.ServerAddresses)[0]) }
            } catch {}
        }

        # CDN через redirector
        try {
            $rnd = [guid]::NewGuid().ToString().Substring(0,8)
            $raw = Invoke-WebRequestFast "http://redirector.googlevideo.com/report_mapping?di=no&nocache=$rnd" 2000
            $cdnShort = $null
            if ($raw -match '=>\s+([\w-]+)') {
                $cdnShort = $matches[1]
            }
            if ($cdnShort -and $cdnShort -ne 'r1') {
                $result.CDN = "r1.$cdnShort.googlevideo.com"
            } else {
                if ($raw -match '=>\s*([a-zA-Z0-9.\-]+\.googlevideo\.com)') {
                    $result.CDN = $matches[1]
                }
            }
        } catch {}

        # GEO — working endpoints first (ip-api / ipapi.co often 403)
        $geoProviders = @(
            @{ Url = "https://api.ip.sb/geoip"; Kind = "ip.sb" },
            @{ Url = "https://ipwhois.app/json/"; Kind = "ipwhois" },
            @{ Url = "https://ipinfo.io/json"; Kind = "ipinfo" },
            @{ Url = "https://ifconfig.co/json"; Kind = "ifconfig" },
            @{ Url = "https://ip-api.com/json/?fields=status,countryCode,city,isp"; Kind = "ip-api" },
            @{ Url = "https://ipapi.co/json/"; Kind = "ipapi" }
        )
        foreach ($gp in $geoProviders) {
            $raw = Invoke-WebRequestFast $gp.Url 2000
            if ($raw -notmatch '\{.*\}') { continue }
            try {
                $data = $raw | ConvertFrom-Json
                $ispVal = $null; $locVal = $null
                switch ($gp.Kind) {
                    "ip.sb" {
                        if ($data.isp -and $data.country_code) {
                            $ispVal = $data.isp
                            $locVal = "$($data.city), $($data.country_code)"
                        }
                    }
                    "ipwhois" {
                        if ($data.success -eq $true -and $data.isp) {
                            $ispVal = $data.isp
                            $locVal = "$($data.city), $($data.country_code)"
                        }
                    }
                    "ipinfo" {
                        if (-not $data.error -and $data.org -and $data.country) {
                            $ispVal = ($data.org -split '\s+', 3)[0..1] -join ' '
                            $locVal = "$($data.city), $($data.country)"
                        }
                    }
                    "ifconfig" {
                        $org = if ($data.asn_org) { $data.asn_org } else { $data.org }
                        $cc = if ($data.country_iso) { $data.country_iso } else { $data.country }
                        if ($org -and $cc) {
                            $ispVal = $org
                            $locVal = if ($data.city) { "$($data.city), $cc" } else { [string]$cc }
                        }
                    }
                    "ip-api" {
                        if ($data.status -eq "success" -and $data.isp) {
                            $ispVal = $data.isp
                            $locVal = "$($data.city), $($data.countryCode)"
                        }
                    }
                    "ipapi" {
                        if (-not $data.error -and $data.org -and $data.country_code) {
                            $ispVal = $data.org
                            $locVal = "$($data.city), $($data.country_code)"
                        }
                    }
                }
                if ($ispVal -and $locVal) {
                    $result.ISP = $ispVal -replace '(?i)\s*(LLC|Inc\.?|Ltd\.?|sp\. z o\.o\.|CJSC|OJSC|PJSC|PAO|ZAO|OOO|JSC|Private Enterprise|Group|Corporation)', ''
                    $result.LOC = $locVal
                    break
                }
            } catch {}
        }

        if ($result.ISP.Length -gt 25) { $result.ISP = $result.ISP.Substring(0, 22) + "..." }

        # IPv6 тест (быстрый)
        try {
            $t = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6)
            $a = $t.BeginConnect("ipv6.google.com", 80, $null, $null)
            if ($a.AsyncWaitHandle.WaitOne(1000)) {
                $t.EndConnect($a)
                $result.HasIPv6 = $true
            }
            $t.Close()
        } catch {}

        $result.TimestampTicks = (Get-Date).Ticks
        return $result
    } | Out-Null
}

# Функция проверки готовности фонового обновления
function Get-ReadyNetInfo {
    $job = Get-Job -Name "NetInfoUpdater" -ErrorAction SilentlyContinue
    if ($job -and $job.State -eq "Completed") {
        $script:BackgroundNetInfo = Receive-Job $job
        Remove-Job $job
        $script:NetInfoUpdating = $false
        Write-DebugLog "Фоновое обновление NetInfo завершено" "INFO"
    }

    if (Test-NetInfoUsable $script:BackgroundNetInfo) {
        return $script:BackgroundNetInfo
    } elseif (Test-NetInfoUsable $script:Config.NetCache) {
        return $script:Config.NetCache
    } else {
        # Возвращаем заглушку, скан начнется мгновенно
        return @{
            DNS = "UNKNOWN"
            CDN = "manifest.googlevideo.com"
            ISP = "Detecting..."
            LOC = "Unknown"
            HasIPv6 = $false
            TimestampTicks = (Get-Date).Ticks
        }
    }
}


# --- НИЗКОУРОВНЕВЫЙ TLS ДВИЖОК (C#) ---
$tlsCode = @"
using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Text;
using System.Linq;
using System.Security.Cryptography;

public class TlsScanner {
    private static void FillRandomBytes(byte[] buffer) {
        using (var rng = RandomNumberGenerator.Create()) {
            rng.GetBytes(buffer);
        }
    }
    public static string TestT13(string targetIp, string host, string proxyHost, int proxyPort, string user, string pass, int timeout) {
        try {
            using (TcpClient tcp = new TcpClient()) {
                string connectHost = string.IsNullOrEmpty(proxyHost) ? targetIp : proxyHost;
                int connectPort = string.IsNullOrEmpty(proxyHost) ? 443 : proxyPort;

                var ar = tcp.BeginConnect(connectHost, connectPort, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeout)) return "DRP";
                tcp.EndConnect(ar);

                NetworkStream stream = tcp.GetStream();
                stream.ReadTimeout = timeout;
                stream.WriteTimeout = timeout;

                if (!string.IsNullOrEmpty(proxyHost)) {
                    byte[] greeting = new byte[] { 0x05, 0x01, 0x00 };
                    stream.Write(greeting, 0, greeting.Length);
                    byte[] authResp = new byte[2];
                    stream.Read(authResp, 0, 2);

                    byte[] connectReq = BuildSocksConnect(host, 443);
                    stream.Write(connectReq, 0, connectReq.Length);
                    byte[] connResp = new byte[10];
                    stream.Read(connResp, 0, 10);
                    if (connResp[1] != 0x00) return "PRX_ERR";
                }

                // Шлем исправленный пакет
                byte[] hello = BuildModernHello(host);
                stream.Write(hello, 0, hello.Length);

                byte[] header = new byte[5];
                int read = 0;
                try {
                    read = stream.Read(header, 0, 5);
                } catch (System.IO.IOException ex) {
                    string m = ex.Message.ToLower();
                    if (m.Contains("reset") || m.Contains("сброс")) return "RST";
                    return "DRP";
                }

                if (read < 5) return "DRP";

                // 0x16 = Handshake (Server Hello) - Успех
                if (header[0] == 0x16) return "OK";

                // 0x15 = TLS Alert. Если сервер прислал это, значит пакет валиден,
                // но серверу что-то не нравится. Для теста доступности это "OK" (сервер ответил).
                if (header[0] == 0x15) return "OK";

                return "DRP";
            }
        } catch (Exception ex) {
            string m = ex.Message.ToLower();
            if (m.Contains("reset") || m.Contains("closed")) return "RST";
            return "DRP";
        }
    }

    private static byte[] BuildSocksConnect(string host, int port) {
        List<byte> req = new List<byte> { 0x05, 0x01, 0x00, 0x03 };
        byte[] h = Encoding.ASCII.GetBytes(host);
        req.Add((byte)h.Length);
        req.AddRange(h);
        req.Add((byte)(port >> 8));
        req.Add((byte)(port & 0xFF));
        return req.ToArray();
    }

    private static byte[] BuildModernHello(string host) {
        List<byte> body = new List<byte>();
        body.AddRange(new byte[] { 0x03, 0x03 }); // TLS 1.2 (for compatibility header)

        byte[] random = new byte[32];
        FillRandomBytes(random);
        body.AddRange(random);

        body.Add(0x00); // Session ID len
        body.AddRange(new byte[] { 0x00, 0x06, 0x13, 0x01, 0x13, 0x02, 0x13, 0x03 }); // Ciphers: TLS_AES_128_GCM_SHA256 и др.
        body.Add(0x20); // Length 32
        byte[] sessId = new byte[32]; FillRandomBytes(sessId);
        body.AddRange(sessId);

        List<byte> exts = new List<byte>();

        // 1. SNI
        byte[] h = Encoding.ASCII.GetBytes(host);
        exts.AddRange(new byte[] { 0x00, 0x00 }); // Type SNI
        int sniLen = h.Length + 5;
        exts.Add((byte)(sniLen >> 8)); exts.Add((byte)(sniLen & 0xFF));
        exts.Add((byte)((h.Length + 3) >> 8)); exts.Add((byte)((h.Length + 3) & 0xFF));
        exts.Add(0x00); // Name type: host_name
        exts.Add((byte)(h.Length >> 8)); exts.Add((byte)(h.Length & 0xFF));
        exts.AddRange(h);

        // 2. Extended Master Secret (0x0017)
        exts.AddRange(new byte[] { 0x00, 0x17, 0x00, 0x00 });

        // 3. Supported Groups (0x000a) - x25519
        exts.AddRange(new byte[] { 0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d });

        // 4. Signature Algorithms (0x000d) - КРИТИЧНО ДЛЯ GOOGLE
        // ecdsa_secp256r1_sha256, rsa_pss_rsae_sha256, rsa_pkcs1_sha256
        exts.AddRange(new byte[] { 0x00, 0x0d, 0x00, 0x08, 0x00, 0x06, 0x04, 0x03, 0x08, 0x04, 0x04, 0x01 });

        // 5. Supported Versions (0x002b) - TLS 1.3
        exts.AddRange(new byte[] { 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04 });

        // 6. PSK Key Exchange Modes (0x002d) - КРИТИЧНО ДЛЯ TLS 1.3
        exts.AddRange(new byte[] { 0x00, 0x2d, 0x00, 0x02, 0x01, 0x01 });

        // 7. Key Share (0x0033)
        exts.AddRange(new byte[] { 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20 });
        byte[] key = new byte[32]; FillRandomBytes(key);
        exts.AddRange(key);

        body.Add((byte)(exts.Count >> 8)); body.Add((byte)(exts.Count & 0xFF));
        body.AddRange(exts);

        List<byte> pkt = new List<byte> { 0x16, 0x03, 0x01 }; // Record Header
        pkt.Add((byte)(body.Count >> 8)); pkt.Add((byte)(body.Count & 0xFF));
        pkt.AddRange(body);
        return pkt.ToArray();
    }
}
"@
$script:TlsScannerLoaded = $false
$script:TlsScannerLoadFailed = $false

function Test-TlsScannerReady {
    if ($script:TlsScannerLoaded -or ([System.Management.Automation.PSTypeName]'TlsScanner').Type) {
        $script:TlsScannerLoaded = $true
        return $true
    }
    return $false
}

function Ensure-TlsScannerLoaded {
    if (Test-TlsScannerReady) { return $true }
    if ($script:TlsScannerLoadFailed) { return $false }

    try {
        Add-Type -TypeDefinition $tlsCode -ErrorAction Stop
        $script:TlsScannerLoaded = $true
        Write-DebugLog "TLS C# компонент загружен" "INFO"
        return $true
    } catch {
        $script:TlsScannerLoadFailed = $true
        Write-DebugLog "Ошибка загрузки TLS C#: $_" "ERROR"
        return $false
    }
}

# --- ГЛОБАЛЬНЫЕ ПУТИ ---
# Лог кладем строго в папку, где лежит сам файл .bat
$script:ParentDir = Split-Path -Parent $script:OriginalFilePath
$DebugLogFile = Join-Path $script:ParentDir "YT-DPI_Debug.log"
# При отладке через env — заголовок сразу в финальный путь к логу (до Load-Config конфиг в логе ещё не виден)
if ($DEBUG_ENABLED) { Write-DebugLogSessionHeaderIfNeeded }

# Конфиг остается в профиле пользователя (AppData)
$script:ConfigDir = Join-Path $env:LOCALAPPDATA "YT-DPI"
$script:ConfigFile = Join-Path $script:ConfigDir "YT-DPI_config.json"

# Создаём папку в AppData, если её нет (для конфига)
if (-not (Test-Path $script:ConfigDir)) {
    try { New-Item -Path $script:ConfigDir -ItemType Directory -Force | Out-Null } catch {}
}


function Normalize-Version($v) {
    $clean = ($v -replace '[^0-9.]', '').Trim('.')
    if (-not $clean) { return [version]"0.0.0" }
    $parts = $clean -split '\.'
    while ($parts.Count -lt 3) { $parts += '0' }
    return [version]($parts[0..2] -join '.')
}

function New-ConfigObject {
    return [PSCustomObject]@{
        RunCount = 0
        LastPromptRun = 0
        LastCheckedVersion = ""
        IpPreference = "IPv6"
        TlsMode = "Auto"       # NEW: "Auto", "TLS12", "TLS13"
        Proxy = @{ Enabled = $false; Type = "HTTP"; Host = ""; Port = 0; User = ""; Pass = "" }
        ProxyHistory = @()
        NetCache = @{
            ISP = "Loading..."; LOC = "Unknown"; DNS = "8.8.8.8";
            CDN = "manifest.googlevideo.com";
            TimestampTicks = (Get-Date).AddDays(-1).Ticks;
            HasIPv6 = $false
        }
        DnsCache = @{}
        DebugLogEnabled = $false
        # true = в заголовке лога полные имя ПК, учётная запись и пути (осторожно при публикации лога)
        DebugLogFullIdentifiers = $false
        # Первый проход T13+T12 через ThreadPool Tasks в воркере нестабилен — по умолчанию выключено.
        ScanParallelTlsFirstPass = $false
        WarnBypassTools = $false
        UiShowLatBars = $true
        UiExtraStrip = $false
        PathMaxHops = 15
        PathSamples = 3
        PathIntervalMs = 200
        GraphWidth = 10
        GraphCharset = "Blocks"  # Blocks | Ascii
    }
}

function Initialize-DisableBrokenParallelTlsTasks {
    if (-not $script:Config) { return }
    if ($null -ne $script:Config.ParallelTlsTasksDisabled032026) { return }
    $script:Config | Add-Member -MemberType NoteProperty -Name "ParallelTlsTasksDisabled032026" -Value $true -Force
    $script:Config | Add-Member -MemberType NoteProperty -Name "ScanParallelTlsFirstPass" -Value $false -Force
    Write-DebugLog "Миграция: параллельный первый проход TLS отключён по умолчанию (ParallelTlsTasksDisabled032026)" "INFO"
    Save-Config $script:Config
}

function Get-PaddedCenter {
    param($text, $width)
    $spaces = $width - $text.Length
    if ($spaces -le 0) { return $text }
    $left = [Math]::Floor($spaces / 2)
    return (" " * $left) + $text
}

function Format-CellCenter {
    param($text, [int]$width)
    $value = [string]$text
    if ($width -le 0) { return "" }
    if ($value.Length -gt $width) { return $value.Substring(0, $width) }
    $left = [Math]::Floor(($width - $value.Length) / 2)
    return ((" " * $left) + $value).PadRight($width)
}

function Format-CellLeft {
    param($text, [int]$width)
    $value = [string]$text
    if ($width -le 0) { return "" }
    if ($value.Length -gt $width) { return $value.Substring(0, $width) }
    return $value.PadRight($width)
}

function New-PlaceholderResultRow {
    param(
        [int]$Number,
        [string]$Target
    )
    return [PSCustomObject]@{
        Number = $Number
        Target = $Target
        IP = "---"
        HTTP = "---"
        T12 = "---"
        T13 = "---"
        Lat = "---"
        Verdict = "IDLE"
        Color = "DarkGray"
    }
}

function New-AbortedResultRow {
    param(
        [int]$Number,
        [string]$Target
    )
    return [PSCustomObject]@{
        Number = $Number
        Target = $Target
        IP = "---"
        HTTP = "---"
        T12 = "---"
        T13 = "---"
        Lat = "---"
        Verdict = "SCAN ABORTED"
        Color = "Yellow"
    }
}

function New-PlaceholderResultRows {
    param([array]$Targets)
    $rows = New-Object 'object[]' $Targets.Count
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        $rows[$i] = New-PlaceholderResultRow -Number ($i + 1) -Target $Targets[$i]
    }
    return $rows
}

# --- Структура конфига в AppData ---
function Load-Config {
    Write-DebugLog "Загрузка конфигурации..."
    $default = New-ConfigObject

    if (Test-Path $script:ConfigFile) {
        try {
            $config = Get-Content $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $config) { return $default }

            # --- МИГРАЦИЯ: Добавляем недостающие поля из дефолтного конфига ---
            foreach ($prop in $default.PSObject.Properties) {
                if ($null -eq $config.$($prop.Name)) {
                    $config | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
                    Write-DebugLog "Миграция: Добавлено отсутствующее поле $($prop.Name)" "INFO"
                }
            }

            # Санитария DNS-кэша
            if ($config.DnsCache -and $config.DnsCache.PSObject) {
                $cleanDns = @{}
                foreach ($p in $config.DnsCache.PSObject.Properties) {
                    if ($p.Value -match '\..*\.' -or $p.Value -match ':') { $cleanDns[$p.Name] = $p.Value }
                }
                $config.DnsCache = $cleanDns
            }

            $lastTicks = if ($config.NetCache.TimestampTicks) { $config.NetCache.TimestampTicks } else { 0 }
            $isStale = (Get-Date).Ticks - $lastTicks -gt ([TimeSpan]::FromHours(6).Ticks)
            $config | Add-Member -MemberType NoteProperty -Name "NetCacheStale" -Value $isStale -Force

            return $config
        } catch {
            Write-DebugLog "Ошибка загрузки: $_" "WARN"
        }
    }
    return $default
}

function Save-Config($config) {
    if ($null -eq $config) { return }
    try {
        # Обновляем DNS кэш перед сохранением
        $config.DnsCache = $script:DnsCache
        $config.Proxy = $global:ProxyConfig

        # Удаляем временное поле
        if ($config.PSObject.Properties['NetCacheStale']) { $config.PSObject.Properties.Remove('NetCacheStale') }

        $json = $config | ConvertTo-Json -Depth 5 -Compress
        Set-Content -Path $script:ConfigFile -Value $json -Encoding UTF8 -Force
        Write-DebugLog "Конфиг сохранен успешно." "INFO"
    } catch {
        Write-DebugLog "Ошибка сохранения: $_" "ERROR"
    }
}

function Test-NetInfoUsable {
    param($NetInfo)
    if ($null -eq $NetInfo) { return $false }
    $isp = [string]$NetInfo.ISP
    $loc = [string]$NetInfo.LOC
    if ([string]::IsNullOrWhiteSpace($isp)) { return $false }
    if ($isp -in @("Loading...", "Detecting...", "Background update", "Unknown", "Geo unavailable")) { return $false }
    if ($loc -in @("Please wait", "Next scan", "Use --fast-mode", "Unknown")) { return $false }
    return $true
}

function Get-SystemDnsPrimary {
    # Prefer WMI; fall back to DnsClient (WWAN/VPN often empty in Win32_NetworkAdapterConfiguration).
    try {
        $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
            Where-Object { $_.DNSServerSearchOrder -ne $null -and @($_.DNSServerSearchOrder).Count -gt 0 } |
            Select-Object -First 1
        if ($wmi) {
            $d = [string](@($wmi.DNSServerSearchOrder)[0])
            if (-not [string]::IsNullOrWhiteSpace($d)) { return $d.Trim() }
        }
    } catch { }
    try {
        $row = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses -and @($_.ServerAddresses).Count -gt 0 } |
            Select-Object -First 1
        if ($row) {
            $d = [string](@($row.ServerAddresses)[0])
            if (-not [string]::IsNullOrWhiteSpace($d)) { return $d.Trim() }
        }
    } catch { }
    return "UNKNOWN"
}

function Get-GeoProviderDefinitions {
    # Order: currently reachable first. ip-api.com / ipapi.co often 403 from datacenter/VPN IPs.
    @(
        [PSCustomObject]@{
            Name   = "api.ip.sb"
            Url    = "https://api.ip.sb/geoip"
            Check  = { param($j) $j.isp -and $j.country_code }
            GetISP = { param($j) $j.isp }
            GetLOC = { param($j) "$($j.city), $($j.country_code)" }
        }
        [PSCustomObject]@{
            Name   = "ipwhois.io"
            Url    = "https://ipwhois.app/json/"
            Check  = { param($j) $j.success -eq $true -and $j.isp }
            GetISP = { param($j) $j.isp }
            GetLOC = { param($j) "$($j.city), $($j.country_code)" }
        }
        [PSCustomObject]@{
            Name   = "ipinfo.io"
            Url    = "https://ipinfo.io/json"
            Check  = { param($j) -not $j.error -and $j.org -and $j.country }
            GetISP = { param($j) ($j.org -split '\s+', 3)[0..1] -join ' ' }
            GetLOC = { param($j) "$($j.city), $($j.country)" }
        }
        [PSCustomObject]@{
            Name   = "ifconfig.co"
            Url    = "https://ifconfig.co/json"
            Check  = { param($j) ($j.asn_org -or $j.org) -and ($j.country_iso -or $j.country) }
            GetISP = { param($j) if ($j.asn_org) { $j.asn_org } else { $j.org } }
            GetLOC = {
                param($j)
                $city = if ($j.city) { [string]$j.city } else { "" }
                $cc = if ($j.country_iso) { [string]$j.country_iso } elseif ($j.country) { [string]$j.country } else { "" }
                if ($city) { "$city, $cc" } else { $cc }
            }
        }
        [PSCustomObject]@{
            Name   = "ip-api.com"
            Url    = "https://ip-api.com/json/?fields=status,countryCode,city,isp"
            Check  = { param($j) $j.status -eq "success" -and $j.isp }
            GetISP = { param($j) $j.isp }
            GetLOC = { param($j) "$($j.city), $($j.countryCode)" }
        }
        [PSCustomObject]@{
            Name   = "ipapi.co"
            Url    = "https://ipapi.co/json/"
            Check  = { param($j) -not $j.error -and $j.org -and $j.country_code }
            GetISP = { param($j) $j.org }
            GetLOC = { param($j) "$($j.city), $($j.country_code)" }
        }
    )
}

function Set-NetInfoCacheIfUsable {
    param($NetInfo)
    if (Test-NetInfoUsable $NetInfo) {
        $script:Config.NetCache = $NetInfo
        return $true
    }
    Write-DebugLog "NetInfo cache not updated: unusable ISP/LOC ($($NetInfo.ISP) / $($NetInfo.LOC))" "WARN"
    return $false
}

function Start-Updater {
    param(
        [Parameter(Mandatory = $true)]
        [string]$currentFile,
        [Parameter(Mandatory = $true)]
        [string]$downloadUrl
    )

    # Проверка входных параметров
    if ([string]::IsNullOrWhiteSpace($currentFile) -or -not (Test-Path -LiteralPath $currentFile -PathType Leaf)) {
        Write-DebugLog "Start-Updater: currentFile='$currentFile' не существует или не указан."
        return
    }

    $parentPid = $pid
    $tempFile = Join-Path $env:TEMP ("YT-DPI_update_" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $logFile = Join-Path $env:TEMP "yt_updater_debug.log"
    $updaterPath = Join-Path $env:TEMP "yt_run_updater.ps1"

    Write-DebugLog "Запуск апдейтера. Лог: $logFile"

    # Получаем родительскую директорию через .NET – надёжно и без «parameter set»
    $mainDir = [System.IO.Path]::GetDirectoryName($currentFile)
    if ([string]::IsNullOrEmpty($mainDir)) {
        Write-DebugLog "Не удалось определить директорию для файла $currentFile"
        return
    }

    $companionUrl = $null
    $companionDest = $null
    if ($currentFile -match '\.(?i)bat$') {
        $companionUrl = "https://raw.githubusercontent.com/Shiperoid/YT-DPI/master/YT-DPI.ps1"
        $companionDest = Join-Path $mainDir "YT-DPI.ps1"
    } elseif ($currentFile -match '\.(?i)ps1$') {
        $companionUrl = "https://raw.githubusercontent.com/Shiperoid/YT-DPI/master/YT-DPI.bat"
        $companionDest = Join-Path $mainDir "YT-DPI.bat"
    }

    # Условия целостности (выражения, которые будут вставлены в генерируемый скрипт)
    if ($currentFile -match '\.(?i)bat$') {
        $integrityExpr = '$size -gt 300 -and ($content -match "YT-DPI.ps1")'
        $compMin = "300"
        $compPat = "YT-DPI.ps1"
    } else {
        $integrityExpr = '$size -gt 8000 -and ($content -match "scriptVersion")'
        $compMin = "8000"
        $compPat = "scriptVersion"
    }

    # Безопасное получение имени файла компаньона
    $companionLeaf = if (-not [string]::IsNullOrEmpty($companionDest)) { [System.IO.Path]::GetFileName($companionDest) } else { "" }
    $compDestEsc = if (-not [string]::IsNullOrEmpty($companionDest)) { $companionDest -replace "'", "''" } else { "" }

    $companionTpl = @'
                try {
                    Write-Log "Downloading companion (REPLACE_COMP_LEAF)..."
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                    $wc2 = New-Object System.Net.WebClient
                    $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
                    $bytes2 = $wc2.DownloadData('REPLACE_COMP_URL')
                    $t2 = [System.Text.Encoding]::UTF8.GetString($bytes2)
                    if ($t2.Length -gt 0 -and [int][char]$t2[0] -eq 0xFEFF) { $t2 = $t2.Substring(1) }
                    $t2 = $t2 -replace "`r`n", "`n" -replace "`n", "`r`n"
                    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
                    $tf2 = Join-Path $env:TEMP ("yt_comp_" + [Guid]::NewGuid().ToString("N") + ".tmp")
                    [System.IO.File]::WriteAllText($tf2, $t2, $utf8WithBom)
                    $sz2 = (Get-Item $tf2).Length
                    $raw2 = Get-Content $tf2 -Raw -Encoding UTF8
                    if ($sz2 -gt REPLACE_COMP_MIN -and ($raw2 -match "REPLACE_COMP_PATTERN")) {
                        Copy-Item -LiteralPath $tf2 -Destination 'REPLACE_COMP_DEST' -Force -ErrorAction Stop
                        Write-Log "Companion installed ($sz2 bytes)."
                    } else { Write-Log "Companion integrity FAIL." }
                    Remove-Item $tf2 -Force -ErrorAction SilentlyContinue
                } catch { Write-Log "Companion error: $($_.Exception.Message)" }
'@

    $companionBlock = ""
    if ($companionUrl -and $companionDest) {
        $companionBlock = $companionTpl.
            Replace("REPLACE_COMP_LEAF", $companionLeaf).
            Replace("REPLACE_COMP_URL", $companionUrl).
            Replace("REPLACE_COMP_MIN", $compMin).
            Replace("REPLACE_COMP_PATTERN", $compPat).
            Replace("REPLACE_COMP_DEST", $compDestEsc)
    }

    # Шаблон апдейтера — все сохранения с BOM (UTF8Encoding $true)
    $updaterTemplate = @'
$parentPid = REPLACE_PID
$currentFile = 'REPLACE_FILE'
$downloadUrl = 'REPLACE_URL'
$tempFile = 'REPLACE_TEMP'
$logFile = 'REPLACE_LOG'

function Write-Log($m) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $m`r`n"
    try { [System.IO.File]::AppendAllText($logFile, $line, [System.Text.Encoding]::UTF8) } catch { }
}

Write-Log "--- UPDATER SESSION START ---"

# 1. Принудительно убиваем старый процесс
Write-Log "Killing old process $parentPid..."
try {
    Stop-Process -Id $parentPid -Force -ErrorAction Stop
    Write-Log "Process killed successfully"
} catch {
    Write-Log "Could not kill process: $_"
}
Start-Sleep -Seconds 1

# 2. Дополнительная проверка, что процесс действительно завершён
$count = 0
while (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) {
    if ($count -gt 30) {
        Write-Log "Force killing again"
        Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
        break
    }
    Start-Sleep -Milliseconds 100
    $count++
}
Start-Sleep -Seconds 1

# 3. Скачивание и замена файла (с конвертацией CRLF и сохранением с BOM)
try {
    Write-Log "Downloading from $downloadUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $web = New-Object System.Net.WebClient
    $web.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $bytes = $web.DownloadData($downloadUrl)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Конвертируем LF -> CRLF
    $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
    # Удаляем BOM, если он был (чтобы не дублировать)
    if ($text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($tempFile, $text, $utf8WithBom)

    Write-Log "Downloaded and fixed. Size: $($text.Length)"

    if (Test-Path $tempFile) {
        $size = (Get-Item $tempFile).Length
        $content = Get-Content $tempFile -Raw -Encoding UTF8
        if (REPLACE_INTEGRITY_EXPR) {
            Write-Log "Integrity check passed."
            $replaced = $false
            for ($i=1; $i -le 5; $i++) {
                try {
                    Copy-Item -Path $tempFile -Destination $currentFile -Force -ErrorAction Stop
                    $replaced = $true
                    Write-Log "File replaced on attempt $i."
                    break
                } catch {
                    Write-Log "Attempt $i failed: $($_.Exception.Message). Retrying..."
                    Start-Sleep -Seconds 1
                }
            }
            if ($replaced) {
REPLACE_COMPANION_BLOCK
                Write-Log "Update successful! Restarting..."
                $dir = [System.IO.Path]::GetDirectoryName($currentFile)
                $rb = [System.IO.Path]::Combine($dir, "YT-DPI.bat")
                if (Test-Path -LiteralPath $rb) { Start-Process -FilePath $rb } else { Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$currentFile" }
            } else {
                Write-Log "CRITICAL: Could not overwrite file."
                $dir = [System.IO.Path]::GetDirectoryName($currentFile)
                $rb = [System.IO.Path]::Combine($dir, "YT-DPI.bat")
                if (Test-Path -LiteralPath $rb) { Start-Process -FilePath $rb } else { Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$currentFile" }
            }
        } else {
            Write-Log "Integrity FAIL."
            $dir = [System.IO.Path]::GetDirectoryName($currentFile)
            $rb = [System.IO.Path]::Combine($dir, "YT-DPI.bat")
            if (Test-Path -LiteralPath $rb) { Start-Process -FilePath $rb } else { Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$currentFile" }
        }
    }
} catch {
    Write-Log "GENERAL ERROR: $($_.Exception.Message)"
    Start-Sleep -Seconds 3
    if (Test-Path $currentFile) {
        $dir = [System.IO.Path]::GetDirectoryName($currentFile)
        $rb = [System.IO.Path]::Combine($dir, "YT-DPI.bat")
        if (Test-Path -LiteralPath $rb) { Start-Process -FilePath $rb } else { Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$currentFile" }
    }
}

Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
Write-Log "--- UPDATER SESSION END ---"
'@

    # Подстановка значений с экранированием для одинарных кавычек
    $updaterContent = $updaterTemplate.
        Replace("REPLACE_PID", $parentPid).
        Replace("REPLACE_FILE", ($currentFile -replace "'", "''")).
        Replace("REPLACE_URL", ($downloadUrl -replace "'", "''")).
        Replace("REPLACE_TEMP", ($tempFile -replace "'", "''")).
        Replace("REPLACE_LOG", ($logFile -replace "'", "''")).
        Replace("REPLACE_INTEGRITY_EXPR", $integrityExpr).
        Replace("REPLACE_COMPANION_BLOCK", $companionBlock)

    # Сохраняем сам апдейтер-скрипт тоже с BOM
    $utf8WithBom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($updaterPath, $updaterContent, $utf8WithBom)

    # Запускаем апдейтер в скрытом окне
    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = "powershell.exe"
    $pInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updaterPath`""
    $pInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [System.Diagnostics.Process]::Start($pInfo) | Out-Null

    Start-Sleep -Milliseconds 500
    exit
}

# ====================================================================================
# Список целей для теста
# ====================================================================================

function Initialize-Targets {
    Write-DebugLog "=== Initialize-Targets: START ===" "DEBUG"
 
    $script:CustomTargetsLoaded = $false
    $script:BaseTargets = @()

    # Определяем директорию скрипта и полный путь к targets.txt
    $parentDir = Split-Path -Parent $script:OriginalFilePath
    $targetsFile = Join-Path $parentDir "targets.txt"
    Write-DebugLog "Определён путь к файлу целей: '$targetsFile' (ParentDir='$parentDir')" "DEBUG"

    $useCustom = $false
    if ($script:Config.UseCustomTargets -eq $true) { 
        $useCustom = $true 
        Write-DebugLog "Настройка UseCustomTargets = true (из конфига)" "DEBUG"
    } else {
        Write-DebugLog "Настройка UseCustomTargets = false или отсутствует, useCustom = false" "DEBUG"
    }

    $fileExists = Test-Path $targetsFile
    Write-DebugLog "Существование файла целей: $fileExists" "DEBUG"

    if ($useCustom -and $fileExists) {
        Write-DebugLog "Попытка загрузить кастомный список целей из файла..." "INFO"
        try {
            $raw = Get-Content -LiteralPath $targetsFile -Encoding UTF8 -ErrorAction Stop
            Write-DebugLog "Прочитано строк из файла: $($raw.Count)" "DEBUG"

            $list = $raw | Where-Object {
                $line = $_.Trim()
                if ([string]::IsNullOrWhiteSpace($line)) { 
                    Write-DebugLog "Пропущена пустая строка" "DEBUG"
                    return $false 
                }
                if ($line.StartsWith('#')) { 
                    Write-DebugLog "Пропущен комментарий: $line" "DEBUG"
                    return $false 
                }
                if ($line -notmatch '\.') { 
                    Write-DebugLog "Пропущена строка без точки: $line" "DEBUG"
                    return $false 
                }
                return $true
            } | ForEach-Object { $_.Trim() }

            Write-DebugLog "После фильтрации осталось целей: $($list.Count)" "DEBUG"
            if ($list.Count -gt 0) {
                $script:BaseTargets = $list
                $script:CustomTargetsLoaded = $true
                Write-DebugLog "Загружено $($list.Count) целей из кастомного файла ($targetsFile)" "INFO"
                Write-DebugLog "=== Initialize-Targets: END (кастомный файл успешно загружен) ===" "DEBUG"
                return
            } else {
                Write-DebugLog "Кастомный файл существует, но не содержит ни одной валидной цели (после фильтрации пусто)." "WARN"
            }
        } catch {
            Write-DebugLog "Ошибка чтения кастомного файла: $($_.Exception.Message)" "ERROR"
            Write-DebugLog "Стек вызова: $($_.ScriptStackTrace)" "DEBUG"
        }
    } else {
        if (-not $useCustom) {
            Write-DebugLog "Использование кастомного файла отключено в конфиге (UseCustomTargets != true)" "DEBUG"
        }
        if (-not $fileExists) {
            Write-DebugLog "Файл кастомных целей не найден по пути: $targetsFile" "DEBUG"
        }
    }

    # Дефолтный список
    Write-DebugLog "Переключение на встроенный (дефолтный) список целей." "INFO"
    $defaultTargets = @(
        "accounts.google.com", "clients6.google.com", "googlevideo.com",
        "googleapis.com", "i.ytimg.com", "m.youtube.com", "manifest.googlevideo.com",
        "music.youtube.com", "play.google.com", "redirector.googlevideo.com",
        "s.ytimg.com", "s.youtube.com", "signaler-pa.youtube.com", "studio.youtube.com",
        "tv.youtube.com", "video.google.com", "www.youtube-nocookie.com", "www.youtube.com",
        "yt3.ggpht.com", "yt4.ggpht.com", "youtu.be", "youtube.com",
        "youtubeembeddedplayer.googleapis.com", "youtubei.googleapis.com", "youtubekids.com"
    )
    $script:BaseTargets = $defaultTargets
    $script:CustomTargetsLoaded = $false
    Write-DebugLog "Используется встроенный список целей ($($defaultTargets.Count) шт.)" "INFO"
    Write-DebugLog "=== Initialize-Targets: END (дефолтный список) ===" "DEBUG"
}

# Функция для получения актуального списка целей
function Get-Targets {
    param($NetInfo)

    $targets = $BaseTargets

    # Добавляем CDN только если НЕ были загружены кастомные цели из файла
    if (-not $script:CustomTargetsLoaded) {
        if ($NetInfo.CDN -and $NetInfo.CDN -notin $targets) {
            $targets += $NetInfo.CDN
        }
    }

    # Сортировка по длине строки + уникальность
    return $targets | Sort-Object { $_.Length } | Select-Object -Unique
}

# ====================================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ И UI
# ====================================================================================
function Out-Str($x, $y, $str, $color="White", $bg="Black") {
    try {
        if ($x -lt 0 -or $y -lt 0) { return }
        $ww = [Console]::WindowWidth
        $wh = [Console]::WindowHeight
        if ($y -ge $wh -or $x -ge $ww) { return }
        $s = [string]$str
        $maxLen = $ww - $x
        if ($maxLen -le 0) { return }
        if ($s.Length -gt $maxLen) { $s = $s.Substring(0, $maxLen) }
        if ($script:UiCursorHidden -ne $true) {
            [Console]::CursorVisible = $false
            $script:UiCursorHidden = $true
        }
        [Console]::SetCursorPosition($x, $y)
        [Console]::ForegroundColor = $color
        [Console]::BackgroundColor = $bg
        [Console]::Write($s)
        [Console]::BackgroundColor = "Black"
    } catch {}
}


# ====================================================================================
# YT-DPI 3.0 TUI ENGINE (classic NAV/STATUS footer + PATH mtr-lite)
# UiFrame / Flush-UiFrame reserved for 3.1 — not used by Draw-UI yet.
# ====================================================================================

$script:UiMode = "Scan"   # Scan | Extra | Dns | Path
$script:UiFrame = $null
$script:UiFrameDirty = $false
$script:LatBarMaxMs = 1
$script:UiCursorHidden = $false

function New-UiFrame {
    param([int]$Width, [int]$Height)
    $rows = New-Object object[] $Height
    for ($y = 0; $y -lt $Height; $y++) {
        $cells = New-Object object[] $Width
        for ($x = 0; $x -lt $Width; $x++) {
            $cells[$x] = [PSCustomObject]@{ Ch = " "; Fg = "Gray"; Bg = "Black" }
        }
        $rows[$y] = $cells
    }
    $script:UiFrame = [PSCustomObject]@{ W = $Width; H = $Height; Rows = $rows }
    $script:UiFrameDirty = $true
}

function Write-UiText {
    param(
        [int]$X,
        [int]$Y,
        [string]$Text,
        [string]$Fg = "Gray",
        [string]$Bg = "Black"
    )
    if (-not $script:UiFrame) { return }
    if ($Y -lt 0 -or $Y -ge $script:UiFrame.H) { return }
    $row = $script:UiFrame.Rows[$Y]
    $s = [string]$Text
    for ($i = 0; $i -lt $s.Length; $i++) {
        $xx = $X + $i
        if ($xx -lt 0 -or $xx -ge $script:UiFrame.W) { continue }
        $row[$xx] = [PSCustomObject]@{ Ch = [string]$s[$i]; Fg = $Fg; Bg = $Bg }
    }
    $script:UiFrameDirty = $true
}

function Clear-UiRow {
    param([int]$Y, [string]$Bg = "Black")
    if (-not $script:UiFrame) { return }
    if ($Y -lt 0 -or $Y -ge $script:UiFrame.H) { return }
    $w = $script:UiFrame.W
    Write-UiText -X 0 -Y $Y -Text (" " * $w) -Fg "Black" -Bg $Bg
}

function Flush-UiFrame {
    param([switch]$Force)
    if (-not $script:UiFrame) { return }
    if (-not $Force -and -not $script:UiFrameDirty) { return }
    try {
        [Console]::CursorVisible = $false
        $h = [Math]::Min($script:UiFrame.H, [Console]::BufferHeight)
        $w = [Math]::Min($script:UiFrame.W, [Console]::BufferWidth)
        for ($y = 0; $y -lt $h; $y++) {
            $row = $script:UiFrame.Rows[$y]
            $x = 0
            while ($x -lt $w) {
                $cell = $row[$x]
                $fg = $cell.Fg; $bg = $cell.Bg
                $sb = New-Object System.Text.StringBuilder
                $start = $x
                while ($x -lt $w -and $row[$x].Fg -eq $fg -and $row[$x].Bg -eq $bg) {
                    [void]$sb.Append($row[$x].Ch)
                    $x++
                }
                try {
                    [Console]::SetCursorPosition($start, $y)
                    [Console]::ForegroundColor = $fg
                    [Console]::BackgroundColor = $bg
                    [Console]::Write($sb.ToString())
                } catch { }
            }
        }
        try { [Console]::BackgroundColor = "Black"; [Console]::ForegroundColor = "Gray" } catch { }
    } catch {
        Write-DebugLog "Flush-UiFrame: $_" "WARN"
    }
    $script:UiFrameDirty = $false
}

function Test-UiExtraStripEnabled {
    # ExtraStrip removed from main TUI (duplicated NAV keys + flickered during scan).
    # Keep stub for config/smoke; always off. EXTRA lives under [E], tips on STATUS.
    return $false
}

function Test-UiShowLatBarsEnabled {
    try {
        if ($script:Config -and ($null -ne $script:Config.UiShowLatBars)) {
            return [bool]$script:Config.UiShowLatBars
        }
    } catch { }
    return $true
}

function Get-GraphCharset {
    $mode = "Blocks"
    try {
        if ($script:Config -and $script:Config.GraphCharset) { $mode = [string]$script:Config.GraphCharset }
    } catch { }
    if ($mode -eq "Ascii") {
        return @{ Bars = "#*=-."; Spark = "#*=-." }
    }
    return @{
        Bars  = ([char]0x2581).ToString() + ([char]0x2582) + ([char]0x2583) + ([char]0x2585) + ([char]0x2586) + ([char]0x2588)
        Spark = ([char]0x2581).ToString() + ([char]0x2582) + ([char]0x2583) + ([char]0x2585) + ([char]0x2586) + ([char]0x2588)
    }
}

function Format-Sparkline {
    param([double[]]$Values, [int]$Width = 8, [double]$Max = 0)
    $cs = Get-GraphCharset
    $chars = $cs.Spark.ToCharArray()
    if (-not $Values -or $Values.Count -eq 0 -or $Width -le 0) { return (" " * [Math]::Max(0, $Width)) }
    $m = $Max
    if ($m -le 0) {
        foreach ($v in $Values) { if ($v -gt $m) { $m = $v } }
    }
    if ($m -le 0) { $m = 1 }
    $out = New-Object System.Text.StringBuilder
    $n = $Values.Count
    for ($i = 0; $i -lt $Width; $i++) {
        $idx = [Math]::Min($n - 1, [int][Math]::Floor($i * $n / $Width))
        $v = [double]$Values[$idx]
        $level = [int][Math]::Floor(($v / $m) * ($chars.Length - 1))
        if ($level -lt 0) { $level = 0 }
        if ($level -ge $chars.Length) { $level = $chars.Length - 1 }
        [void]$out.Append($chars[$level])
    }
    return $out.ToString()
}

function Format-LatBar {
    param([string]$LatText, [int]$Width = 6)
    if (-not (Test-UiShowLatBarsEnabled)) { return $null }
    if ($Width -lt 1) { return $null }
    $ms = 0
    if ($LatText -match '^\d+') { $ms = [int]$Matches[0] }
    if ($ms -le 0) { return (" " * $Width) }
    $max = [Math]::Max(1, [int]$script:LatBarMaxMs)
    # Fill bar by ratio ms/max (NOT a sparkline of one repeated sample).
    $ratio = [double]$ms / [double]$max
    if ($ratio -gt 1) { $ratio = 1 }
    if ($ratio -lt 0) { $ratio = 0 }
    $filled = [int][Math]::Floor($ratio * $Width + 0.0001)
    if ($ms -gt 0 -and $filled -lt 1 -and $Width -ge 1) { $filled = 1 }
    if ($filled -gt $Width) { $filled = $Width }
    $fullCh = "#"
    $emptyCh = "."
    try {
        $mode = "Blocks"
        if ($script:Config -and $script:Config.GraphCharset) { $mode = [string]$script:Config.GraphCharset }
        if ($mode -ne "Ascii") {
            $fullCh = [string]([char]0x2588)   # full block
            $emptyCh = " "                     # no ░ trail — empty = spaces
        }
    } catch { }
    return (($fullCh * $filled) + ($emptyCh * ($Width - $filled)))
}

function Format-LatCell {
    param(
        [string]$LatText,
        [int]$TotalWidth = 12,
        [int]$NumWidth = 4,
        [int]$BarWidth = 6
    )
    $raw = if ($LatText) { [string]$LatText } else { "---" }
    $num = "---"
    if ($raw -match '^\d+') { $num = $Matches[0] }
    elseif ($raw -eq "---") { $num = "---" }
    if ($num.Length -gt $NumWidth) {
        $numPad = $num.Substring($num.Length - $NumWidth)
    } else {
        $numPad = $num.PadLeft($NumWidth)
    }
    $bar = (" " * $BarWidth)
    if ($num -match '^\d+') {
        $drawn = Format-LatBar -LatText $num -Width $BarWidth
        if ($drawn) {
            if ($drawn.Length -gt $BarWidth) { $drawn = $drawn.Substring(0, $BarWidth) }
            $bar = $drawn.PadRight($BarWidth).Substring(0, $BarWidth)
        }
    }
    $combo = $numPad + " " + $bar
    if ($combo.Length -gt $TotalWidth) { return $combo.Substring(0, $TotalWidth) }
    return $combo.PadRight($TotalWidth)
}

function Update-LatBarScale {
    param($Results)
    $max = 1
    if ($Results) {
        foreach ($r in @($Results)) {
            if (-not $r -or -not $r.Lat) { continue }
            $t = [string]$r.Lat
            if ($t -match '^\d+') {
                $v = [int]$Matches[0]
                if ($v -gt $max) { $max = $v }
            }
        }
    }
    # Headroom so the slowest host is not a solid full bar.
    $script:LatBarMaxMs = [Math]::Max([int][Math]::Ceiling($max * 1.15), $max + 1)
}

function Get-UiLayout {
    param([int]$TargetCount = 0)
    if ($TargetCount -le 0 -and $script:Targets) { $TargetCount = @($script:Targets).Count }
    $wh = 30
    try { $wh = [Console]::WindowHeight } catch { }
    if ($wh -lt 8) { $wh = 8 }

    $tableStart = 9
    $tableHeader = 3
    $tableBodyStart = $tableStart + $tableHeader   # 12
    # Sticky footer: NAV + STATUS always at bottom of window.
    $navRow = $wh - 2
    $feedbackRow = $wh - 1
    if ($navRow -le $tableBodyStart) {
        $navRow = [Math]::Max(1, $wh - 2)
        $feedbackRow = [Math]::Max($navRow + 1, $wh - 1)
        if ($feedbackRow -ge $wh) { $feedbackRow = $wh - 1 }
        if ($navRow -ge $feedbackRow) { $navRow = [Math]::Max(0, $feedbackRow - 1) }
    }

    # Body + bottom rule must sit above NAV.
    $maxBody = $navRow - $tableBodyStart - 1
    if ($maxBody -lt 1) { $maxBody = 1 }
    $visibleRows = [Math]::Min([Math]::Max(0, $TargetCount), $maxBody)
    $tableEnd = $tableBodyStart + [Math]::Max(0, $visibleRows) - 1
    $bottomRuleRow = $tableBodyStart + $visibleRows
    if ($bottomRuleRow -ge $navRow) {
        $visibleRows = [Math]::Max(1, $navRow - $tableBodyStart - 1)
        $tableEnd = $tableBodyStart + $visibleRows - 1
        $bottomRuleRow = $tableBodyStart + $visibleRows
    }
    $maxScroll = [Math]::Max(0, $TargetCount - $visibleRows)

    return [PSCustomObject]@{
        TableStart     = $tableStart
        TableBodyStart = $tableBodyStart
        TableEnd       = $tableEnd
        VisibleRows    = $visibleRows
        BottomRuleRow  = $bottomRuleRow
        ExtraStart     = $navRow
        ExtraHeight    = 0
        NavRow         = $navRow
        FeedbackRow    = $feedbackRow
        WindowHeight   = $wh
        TargetCount    = $TargetCount
        MaxScroll      = $maxScroll
    }
}

function Clamp-TableScroll {
    param([int]$TargetCount = -1)
    if ($TargetCount -lt 0) {
        $TargetCount = if ($script:Targets) { @($script:Targets).Count } else { 0 }
    }
    if ($null -eq $script:TableScrollOffset) { $script:TableScrollOffset = 0 }
    $layout = Get-UiLayout -TargetCount $TargetCount
    $maxOff = [int]$layout.MaxScroll
    if ($script:TableScrollOffset -lt 0) { $script:TableScrollOffset = 0 }
    if ($script:TableScrollOffset -gt $maxOff) { $script:TableScrollOffset = $maxOff }
    return $layout
}

function Get-TableScreenRow {
    param(
        [int]$TargetIndex,
        [int]$TargetCount = -1
    )
    $layout = Clamp-TableScroll -TargetCount $TargetCount
    $off = [int]$script:TableScrollOffset
    $vis = [int]$layout.VisibleRows
    if ($vis -le 0) { return -1 }
    if ($TargetIndex -lt $off -or $TargetIndex -ge ($off + $vis)) { return -1 }
    return ([int]$layout.TableBodyStart + ($TargetIndex - $off))
}

function Get-TableViewportIndexRange {
    param([int]$TargetCount = -1)
    if ($TargetCount -lt 0) {
        $TargetCount = if ($script:Targets) { @($script:Targets).Count } else { 0 }
    }
    $layout = Clamp-TableScroll -TargetCount $TargetCount
    $off = [int]$script:TableScrollOffset
    $vis = [int]$layout.VisibleRows
    if ($vis -le 0 -or $TargetCount -le 0) {
        return [PSCustomObject]@{
            StartIdx = 0
            EndIdx   = -1
            Layout   = $layout
        }
    }
    $end = [Math]::Min($TargetCount, $off + $vis) - 1
    return [PSCustomObject]@{
        StartIdx = $off
        EndIdx   = $end
        Layout   = $layout
    }
}

function Invoke-TableScrollKey {
    param($Key)
    $n = if ($script:Targets) { $script:Targets.Count } else { 0 }
    if ($n -le 0) { return $false }
    $layout = Clamp-TableScroll -TargetCount $n
    $vis = [Math]::Max(1, [int]$layout.VisibleRows)
    $old = [int]$script:TableScrollOffset
    switch ([string]$Key) {
        "UpArrow" { $script:TableScrollOffset-- }
        "DownArrow" { $script:TableScrollOffset++ }
        "PageUp" { $script:TableScrollOffset -= $vis }
        "PageDown" { $script:TableScrollOffset += $vis }
        "Home" { $script:TableScrollOffset = 0 }
        "End" { $script:TableScrollOffset = [int]::MaxValue / 4 }
        default { return $false }
    }
    $null = Clamp-TableScroll -TargetCount $n
    return ([int]$script:TableScrollOffset -ne $old)
}

function Test-IsTableScrollKey {
    param($Key)
    # Prefer ConsoleKey enum equality (same as legacy $k -eq "UpArrow")
    try {
        return (
            $Key -eq [ConsoleKey]::UpArrow -or
            $Key -eq [ConsoleKey]::DownArrow -or
            $Key -eq [ConsoleKey]::PageUp -or
            $Key -eq [ConsoleKey]::PageDown -or
            $Key -eq [ConsoleKey]::Home -or
            $Key -eq [ConsoleKey]::End
        )
    } catch {
        return ([string]$Key -in @("UpArrow", "DownArrow", "PageUp", "PageDown", "Home", "End"))
    }
}

# Apply FirstKey + drain queued scroll keys, paint viewport once. Stashes non-scroll key in PendingMainKey.
function Invoke-CoalescedTableScroll {
    param(
        $FirstKey,
        $Results = $null
    )
    $oldOff = [int]$script:TableScrollOffset
    $moved = [bool](Invoke-TableScrollKey $FirstKey)
    while ([Console]::KeyAvailable) {
        $nk = [Console]::ReadKey($true).Key
        if (Test-IsTableScrollKey $nk) {
            if (Invoke-TableScrollKey $nk) { $moved = $true }
        } else {
            $script:PendingMainKey = $nk
            break
        }
    }
    if ($moved) {
        try {
            $newOff = [int]$script:TableScrollOffset
            $delta = $newOff - $oldOff
            # Net scroll within one viewport: atomic buffer shift + paint only new rows.
            # |delta|>=visibleRows -> full redraw (Home/End / large Page jumps).
            $nQuick = if ($script:Targets) { [int]$script:Targets.Count } else { 0 }
            $layQuick = $null
            try { $layQuick = Get-UiLayout -TargetCount $nQuick } catch { }
            $visQuick = if ($layQuick) { [int]$layQuick.VisibleRows } else { 1 }
            if ($delta -ne 0 -and [Math]::Abs($delta) -lt [Math]::Max(1, $visQuick)) {
                Update-TableViewportCellsDelta -Results $Results -Delta $delta
            } else {
                Update-TableViewportCells -Results $Results
            }
        } catch {
            try { Update-TableViewportCells -Results $Results } catch { }
        }
    }
    return $moved
}

function ConvertTo-UiConsoleColor {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return [ConsoleColor]::Gray }
    try { return [System.Enum]::Parse([ConsoleColor], $Name, $true) } catch { return [ConsoleColor]::Gray }
}

function Set-BufferRowSpan {
    param(
        [System.Management.Automation.Host.BufferCell[,]]$Buf,
        [int]$Row,
        [int]$X,
        [string]$Text,
        [string]$Fg,
        [string]$Bg = "Black",
        [int]$BufWidth
    )
    if ($Row -lt 0 -or $X -lt 0 -or $X -ge $BufWidth) { return }
    $fgc = ConvertTo-UiConsoleColor $Fg
    $bgc = ConvertTo-UiConsoleColor $Bg
    $s = [string]$Text
    $max = $BufWidth - $X
    if ($max -le 0) { return }
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    for ($i = 0; $i -lt $s.Length; $i++) {
        $Buf[$Row, ($X + $i)] = New-Object System.Management.Automation.Host.BufferCell (
            [char]$s[$i], $fgc, $bgc, [System.Management.Automation.Host.BufferCellType]::Complete
        )
    }
}

function Clear-BufferRowLine {
    param(
        [System.Management.Automation.Host.BufferCell[,]]$Buf,
        [int]$Row,
        [int]$BufWidth
    )
    $blank = New-Object System.Management.Automation.Host.BufferCell (
        [char]' ', [ConsoleColor]::Black, [ConsoleColor]::Black, [System.Management.Automation.Host.BufferCellType]::Complete
    )
    for ($x = 0; $x -lt $BufWidth; $x++) { $Buf[$Row, $x] = $blank }
}

function Fill-TableBodyRowBuffer {
    param(
        [System.Management.Automation.Host.BufferCell[,]]$Buf,
        [int]$Row,
        [int]$BufWidth,
        [int]$TargetIndex,
        $Results = $null,
        [int]$ResultsCount = 0,
        $Pos = $null
    )
    Clear-BufferRowLine -Buf $Buf -Row $Row -BufWidth $BufWidth
    if (-not $script:Targets -or -not $Pos) { return }
    $n = $script:Targets.Count
    if ($TargetIndex -lt 0 -or $TargetIndex -ge $n) { return }

    $tgt = [string]$script:Targets[$TargetIndex]
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.Num) -Text (Format-CellCenter (($TargetIndex + 1).ToString()) 4) -Fg "Cyan" -BufWidth $BufWidth
    if ($tgt.Length -lt 42) { $tgtPad = $tgt.PadRight(42) }
    elseif ($tgt.Length -gt 42) { $tgtPad = $tgt.Substring(0, 42) }
    else { $tgtPad = $tgt }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.Dom) -Text $tgtPad -Fg "Gray" -BufWidth $BufWidth

    $res = $null
    if ($TargetIndex -lt $ResultsCount) { $res = $Results[$TargetIndex] }
    if ($null -eq $res) {
        $res = New-PlaceholderResultRow -Number ($TargetIndex + 1) -Target $tgt
    }

    $ipWidth = if ($script:IpColumnWidth) { $script:IpColumnWidth } else { 16 }
    $ipStr = if ($res.IP) { [string]$res.IP } else { "---" }
    if ($ipStr.Length -gt $ipWidth) { $ipStr = $ipStr.Substring(0, $ipWidth - 2) + ".." }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.IP) -Text ($ipStr.PadRight($ipWidth).Substring(0, $ipWidth)) -Fg "DarkGray" -BufWidth $BufWidth

    $htStr = if ($res.HTTP) { [string]$res.HTTP } else { "---" }
    $hCol = if ($htStr -eq "OK") { "Green" } elseif ($htStr -eq "---") { "DarkGray" } else { "Red" }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.HTTP) -Text (Format-CellCenter $htStr 6) -Fg $hCol -BufWidth $BufWidth

    $t12Str = if ($res.T12) { [string]$res.T12 } else { "---" }
    $t12Str = Format-TlsCellDisplay -Cell $t12Str -RstPhase $res.RstPhase12
    $t12Col = if ($t12Str -eq "OK") { "Green" } elseif ($t12Str -eq "N/A" -or $t12Str -eq "---") { "DarkGray" } else { "Red" }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.T12) -Text (Format-CellCenter $t12Str 8) -Fg $t12Col -BufWidth $BufWidth

    $t13Str = if ($res.T13) { [string]$res.T13 } else { "---" }
    $t13Str = Format-TlsCellDisplay -Cell $t13Str -RstPhase $res.RstPhase13
    $t13Col = if ($t13Str -eq "OK") { "Green" } elseif ($t13Str -eq "N/A" -or $t13Str -eq "---") { "DarkGray" } else { "Red" }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.T13) -Text (Format-CellCenter $t13Str 8) -Fg $t13Col -BufWidth $BufWidth

    $latStr = if ($res.Lat) { [string]$res.Lat } else { "---" }
    $latCol = if ($latStr -eq "---") { "DarkGray" } else { "Cyan" }
    $latW = 12
    try {
        if ($Pos.Ver -gt $Pos.Lat) { $latW = [Math]::Max(12, [int]$Pos.Ver - [int]$Pos.Lat - 2) }
    } catch { }
    $latCell = Format-LatCell -LatText $latStr -TotalWidth $latW -NumWidth 4 -BarWidth 6
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.Lat) -Text $latCell -Fg $latCol -BufWidth $BufWidth

    $verStr = if ($res.Verdict) { [string]$res.Verdict } else { "UNKNOWN" }
    $verCol = if ($res.Color) { [string]$res.Color } else { "Gray" }
    Set-BufferRowSpan -Buf $Buf -Row $Row -X ([int]$Pos.Ver) -Text (Format-CellCenter $verStr 18) -Fg $verCol -BufWidth $BufWidth
}

function Write-TableBodyRowAt {
    param(
        [int]$TargetIndex,
        [int]$ScreenRow,
        $Results = $null,
        [int]$ResultsCount = -1,
        $Pos = $null
    )
    if (-not $script:Targets) { return }
    $n = $script:Targets.Count
    if ($ScreenRow -lt 0) { return }
    try {
        $wh = [Console]::WindowHeight
        if ($ScreenRow -ge ($wh - 2)) { return }
    } catch { }
    if (-not $Pos) {
        if (-not $script:DynamicColPos) { Sync-DynamicColPosFromLayout }
        $Pos = $script:DynamicColPos
    }
    $width = [Console]::WindowWidth
    if ($TargetIndex -lt 0 -or $TargetIndex -ge $n) {
        Out-Str 0 $ScreenRow (" " * $width) "Black" "Black"
        return
    }
    if ($ResultsCount -lt 0) {
        $ResultsCount = 0
        if ($null -ne $Results) {
            try { $ResultsCount = [int]$Results.Count } catch { $ResultsCount = @($Results).Count }
        }
    }
    $tgt = [string]$script:Targets[$TargetIndex]
    Out-Str $Pos.Num $ScreenRow (Format-CellCenter (($TargetIndex + 1).ToString()) 4) "Cyan"
    if ($tgt.Length -lt 42) { $tgtPad = $tgt.PadRight(42) }
    elseif ($tgt.Length -gt 42) { $tgtPad = $tgt.Substring(0, 42) }
    else { $tgtPad = $tgt }
    Out-Str $Pos.Dom $ScreenRow $tgtPad "Gray"
    $res = $null
    if ($TargetIndex -lt $ResultsCount) { $res = $Results[$TargetIndex] }
    if ($null -eq $res) {
        $res = New-PlaceholderResultRow -Number ($TargetIndex + 1) -Target $tgt
    }
    Write-ResultLine -row $ScreenRow -result $res -TrustedBodyRow
}

function Update-TableViewportCellsDelta {
    param(
        $Results = $null,
        [int]$Delta = 0
    )
    if (-not $script:Targets) { return }
    if ($Delta -eq 0) { return }
    if ($script:UiCursorHidden -ne $true) {
        [Console]::CursorVisible = $false
        $script:UiCursorHidden = $true
    }
    if (-not $script:DynamicColPos) { Sync-DynamicColPosFromLayout }

    $n = $script:Targets.Count
    $layout = Clamp-TableScroll -TargetCount $n
    $off = [int]$script:TableScrollOffset
    $vis = [int]$layout.VisibleRows
    $bodyStart = [int]$layout.TableBodyStart
    $navRow = [int]$layout.NavRow
    $width = [Console]::WindowWidth
    $pos = $script:DynamicColPos

    # Never paint into sticky footer even if WindowHeight reports large.
    try {
        $wh = [Console]::WindowHeight
        if ($navRow -ge $wh) { $navRow = $wh - 2 }
        $maxVis = [Math]::Max(1, $navRow - $bodyStart - 1)
        if ($vis -gt $maxVis) { $vis = $maxVis }
    } catch { }

    $step = [Math]::Abs($Delta)
    if ($vis -le 1 -or $step -ge $vis) {
        Update-TableViewportCells -Results $Results
        return
    }

    if ($null -eq $Results) { $Results = Get-MainTableResults }
    $resCount = 0
    if ($null -ne $Results) {
        try { $resCount = [int]$Results.Count } catch { $resCount = @($Results).Count }
    }

    # Atomic body update: shift BufferCell[,] in memory + one SetBufferContents (no MoveBufferArea / cell Out-Str flicker).
    try {
        $raw = $Host.UI.RawUI
        $bw = [Math]::Min($width, [int]$raw.BufferSize.Width)
        if ($bw -lt 8) { throw "buffer too narrow" }
        $right = $bw - 1
        $bottom = $bodyStart + $vis - 1
        $rect = New-Object System.Management.Automation.Host.Rectangle 0, $bodyStart, $right, $bottom
        $buf = $raw.GetBufferContents($rect)
        $h = $buf.GetLength(0)
        $w = $buf.GetLength(1)
        if ($h -lt $vis) { $vis = $h }
        if ($step -ge $vis) { throw "step>=vis after get" }

        if ($Delta -gt 0) {
            for ($r = 0; $r -lt ($vis - $step); $r++) {
                for ($x = 0; $x -lt $w; $x++) { $buf[$r, $x] = $buf[($r + $step), $x] }
            }
            for ($s = 0; $s -lt $step; $s++) {
                $slot = ($vis - $step) + $s
                Fill-TableBodyRowBuffer -Buf $buf -Row $slot -BufWidth $w -TargetIndex ($off + $slot) `
                    -Results $Results -ResultsCount $resCount -Pos $pos
            }
        } else {
            for ($r = ($vis - 1); $r -ge $step; $r--) {
                for ($x = 0; $x -lt $w; $x++) { $buf[$r, $x] = $buf[($r - $step), $x] }
            }
            for ($s = 0; $s -lt $step; $s++) {
                Fill-TableBodyRowBuffer -Buf $buf -Row $s -BufWidth $w -TargetIndex ($off + $s) `
                    -Results $Results -ResultsCount $resCount -Pos $pos
            }
        }
        $origin = New-Object System.Management.Automation.Host.Coordinates 0, $bodyStart
        $raw.SetBufferContents($origin, $buf)
        Update-TableBottomScrollRule -Layout $layout
    } catch {
        # Fallback: MoveBufferArea + Out-Str path
        try {
            if ($Delta -gt 0) {
                [Console]::MoveBufferArea(0, ($bodyStart + $step), $width, ($vis - $step), 0, $bodyStart)
                for ($s = 0; $s -lt $step; $s++) {
                    $slot = ($vis - $step) + $s
                    $rowNew = $bodyStart + $slot
                    if ($rowNew -ge $navRow) { break }
                    Write-TableBodyRowAt -TargetIndex ($off + $slot) -ScreenRow $rowNew -Results $Results -ResultsCount $resCount -Pos $pos
                }
            } else {
                [Console]::MoveBufferArea(0, $bodyStart, $width, ($vis - $step), 0, ($bodyStart + $step))
                for ($s = 0; $s -lt $step; $s++) {
                    $rowNew = $bodyStart + $s
                    if ($rowNew -ge $navRow) { break }
                    Write-TableBodyRowAt -TargetIndex ($off + $s) -ScreenRow $rowNew -Results $Results -ResultsCount $resCount -Pos $pos
                }
            }
            Update-TableBottomScrollRule -Layout $layout
        } catch {
            Update-TableViewportCells -Results $Results
        }
    }
}

function Update-TableBottomScrollRule {
    param($Layout = $null, [int]$TargetCount = -1)
    if ($null -eq $Layout) {
        if ($TargetCount -lt 0) {
            $TargetCount = if ($script:Targets) { @($script:Targets).Count } else { 0 }
        }
        $Layout = Clamp-TableScroll -TargetCount $TargetCount
    }
    $width = [Console]::WindowWidth
    $bottomRule = [int]$Layout.BottomRuleRow
    $off = [int]$script:TableScrollOffset
    $vis = [int]$Layout.VisibleRows
    $n = [int]$Layout.TargetCount
    $rule = ("=" * $width)
    if ($Layout.MaxScroll -gt 0 -and $n -gt 0) {
        $from = $off + 1
        $to = [Math]::Min($n, $off + $vis)
        $hint = " $from-$to/$n  Up/Dn PgUp/PgDn "
        if ($hint.Length + 4 -lt $width) {
            $left = [Math]::Floor(($width - $hint.Length) / 2)
            if ($left -lt 2) { $left = 2 }
            $rule = ("=" * $left) + $hint + ("=" * [Math]::Max(0, $width - $left - $hint.Length))
            if ($rule.Length -gt $width) { $rule = $rule.Substring(0, $width) }
        }
    }
    Out-Str 0 $bottomRule $rule "DarkCyan"
}

function Update-TableViewportCells {
    param($Results = $null)
    # Fast scroll path: body cells + bottom rule only. No Clear / logo / STATUS / Add-Member.
    if (-not $script:Targets) { return }
    if ($script:UiCursorHidden -ne $true) {
        [Console]::CursorVisible = $false
        $script:UiCursorHidden = $true
    }
    if (-not $script:DynamicColPos) { Sync-DynamicColPosFromLayout }

    $n = $script:Targets.Count
    $layout = Clamp-TableScroll -TargetCount $n
    $off = [int]$script:TableScrollOffset
    $vis = [int]$layout.VisibleRows
    $bodyStart = [int]$layout.TableBodyStart
    $navRow = [int]$layout.NavRow
    $pos = $script:DynamicColPos
    if (-not $pos) { Sync-DynamicColPosFromLayout; $pos = $script:DynamicColPos }
    try {
        $wh = [Console]::WindowHeight
        if ($navRow -ge $wh) { $navRow = $wh - 2 }
        $maxVis = [Math]::Max(1, $navRow - $bodyStart - 1)
        if ($vis -gt $maxVis) { $vis = $maxVis }
    } catch { }

    if ($null -eq $Results) { $Results = Get-MainTableResults }
    $resCount = 0
    if ($null -ne $Results) {
        try { $resCount = [int]$Results.Count } catch { $resCount = @($Results).Count }
    }

    for ($slot = 0; $slot -lt $vis; $slot++) {
        $i = $off + $slot
        $row = $bodyStart + $slot
        if ($row -ge $navRow) { break }
        Write-TableBodyRowAt -TargetIndex $i -ScreenRow $row -Results $Results -ResultsCount $resCount -Pos $pos
    }
    Update-TableBottomScrollRule -Layout $layout
}

function Invoke-TableViewportRedraw {
    param(
        $Results = $null,
        [bool]$ClearScreen = $false
    )
    if ($ClearScreen) {
        $rows = $Results
        if ($null -eq $rows) { $rows = Get-MainTableResults }
        $null = Clamp-TableScroll
        Draw-UI $script:NetInfo $script:Targets $rows $true
        Draw-StatusBar
        return
    }
    Update-TableViewportCells -Results $Results
}

function Get-ExtraChipLine {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($script:ExtraDiag.Dns -and @($script:ExtraDiag.Dns).Count -gt 0) {
        $bad = @($script:ExtraDiag.Dns | Where-Object { $_.Status -ne "OK" }).Count
        $st = if ($bad -gt 0) { "DNS!$bad" } else { "DNS OK" }
        [void]$parts.Add($st)
    }
    if ($script:ExtraDiag.Quic) {
        [void]$parts.Add(("QUIC {0}" -f $script:ExtraDiag.Quic.Summary))
    }
    if ($script:ExtraDiag.Tcp16) {
        [void]$parts.Add(("TCP16 {0}" -f $script:ExtraDiag.Tcp16.Status))
    }
    if ($script:ExtraDiag.IpVsSni) {
        [void]$parts.Add(("SNI {0}" -f $script:ExtraDiag.IpVsSni.Status))
    }
    if ($parts.Count -eq 0) { return "[ EXTRA ] (run scan)" }
    return "[ EXTRA ] " + ($parts -join " | ")
}

function Draw-ExtraStrip {
    # Intentionally empty: third footer panel removed (button dupes + scan flicker).
    return
}

function Format-TlsCellDisplay {
    param([string]$Cell, [string]$RstPhase)
    if ($Cell -eq "RST" -and $RstPhase -eq "RST_CH") { return "RST*" }
    return $Cell
}

function Invoke-IcmpTtlPathProbe {
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$MaxHops = 15,
        [int]$Samples = 3,
        [int]$IntervalMs = 200,
        [int]$TimeoutMs = 1000,
        [scriptblock]$OnProgress = $null
    )
    $ip = $null
    try {
        $ip = ([System.Net.Dns]::GetHostAddresses($Target) |
            Where-Object { $_.AddressFamily -eq "InterNetwork" } |
            Select-Object -First 1)
    } catch { }
    if (-not $ip) {
        return @([PSCustomObject]@{
                Hop = 0; Ip = $null; LossPct = 100; Last = $null; Avg = $null; Best = $null; Samples = @(); Status = "N/A"
            })
    }
    $dest = $ip.IPAddressToString
    $hops = @()
    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq "Escape") { break }
        }
        $rtts = New-Object System.Collections.Generic.List[double]
        $replyIp = $null
        $timeouts = 0
        for ($s = 0; $s -lt $Samples; $s++) {
            try {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
                $buf = New-Object byte[] 32
                $reply = $ping.Send($dest, $TimeoutMs, $buf, $opts)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success -or
                    $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired) {
                    [void]$rtts.Add([double]$reply.RoundtripTime)
                    if ($reply.Address) { $replyIp = $reply.Address.ToString() }
                } else {
                    $timeouts++
                }
                try { $ping.Dispose() } catch { }
            } catch {
                $timeouts++
            }
            if ($IntervalMs -gt 0 -and $s -lt $Samples -1) { Start-Sleep -Milliseconds $IntervalMs }
        }
        $loss = [int](100.0 * $timeouts / [Math]::Max(1, $Samples))
        $last = $null; $avg = $null; $best = $null
        if ($rtts.Count -gt 0) {
            $last = [int]$rtts[$rtts.Count - 1]
            $sum = 0.0
            $bestD = [double]::MaxValue
            foreach ($v in $rtts) {
                $sum += $v
                if ($v -lt $bestD) { $bestD = $v }
            }
            $avg = [int]($sum / $rtts.Count)
            $best = [int]$bestD
        }
        $status = if ($rtts.Count -eq 0) { "TIMEOUT" } elseif ($replyIp -eq $dest) { "DONE" } else { "HOP" }
        $hopObj = [PSCustomObject]@{
            Hop = $ttl; Ip = $replyIp; LossPct = $loss; Last = $last; Avg = $avg; Best = $best
            Samples = @($rtts); Status = $status
        }
        $hops += $hopObj
        if ($OnProgress) { & $OnProgress $hopObj $hops }
        if ($status -eq "DONE") { break }
    }
    # Optional final TCP RTT to :443 (single sample)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($ip, 443, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500)
        if ($ok) {
            try { $tcp.EndConnect($ar) } catch { $ok = $false }
        }
        $sw.Stop()
        try { $tcp.Close() } catch { }
        if ($ok) {
            $hops += [PSCustomObject]@{
                Hop = 0; Ip = $dest; LossPct = 0; Last = [int]$sw.ElapsedMilliseconds
                Avg = [int]$sw.ElapsedMilliseconds; Best = [int]$sw.ElapsedMilliseconds
                Samples = @([double]$sw.ElapsedMilliseconds); Status = "TCP443"
            }
        }
    } catch { }
    return $hops
}

function Test-ActiveVpnAdapterHint {
    # Best-effort: common VPN/tunnel adapters. False negatives OK — proxy + hop collapse still catch most cases.
    try {
        $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })
        foreach ($a in $up) {
            $blob = ("{0} {1}" -f $a.Name, $a.InterfaceDescription)
            if ($blob -match '(?i)TAP|TUN|Wintun|WireGuard|OpenVPN|NordLynx|Cloudflare|WARP|ZeroTier|Hamachi|SoftEther|AnyConnect|GlobalProtect|Outline|Mullvad|Proton|VPN') {
                return [string]$a.Name
            }
        }
    } catch { }
    return $null
}

function Get-PathProbeBlockReason {
    # PATH is raw ICMP TTL — it never goes through app HTTP/SOCKS proxy and is useless inside most VPN tunnels.
    if ($global:ProxyConfig -and $global:ProxyConfig.Enabled) {
        $px = "{0} {1}:{2}" -f $global:ProxyConfig.Type, $global:ProxyConfig.Host, $global:ProxyConfig.Port
        return ("Включён прокси ($px). PATH не ходит через прокси (сырой ICMP) — отключите прокси в [P] или проверьте маршрут иначе.")
    }
    $vpn = Test-ActiveVpnAdapterHint
    if ($vpn) {
        return ("Похож активный VPN ($vpn). Часто сырой ICMP PATH схлопывается (1 hop / 0 ms) — отключите VPN или туннель.")
    }
    return $null
}

function Test-PathHopsCollapsedTunnel {
    param(
        $Hops,
        [string]$DestIp = $null
    )
    $real = @($Hops | Where-Object { $_ -and $_.Hop -gt 0 })
    if ($real.Count -eq 0) { return $true }
    if ($real.Count -gt 2) { return $false }
    $h1 = $real[0]
    $ip = if ($h1.Ip) { [string]$h1.Ip } else { "" }
    $avg = if ($null -ne $h1.Avg) { [double]$h1.Avg } else { -1 }
    $toDest = ($h1.Status -eq "DONE") -or ($DestIp -and $ip -eq $DestIp)
    # Typical VPN/proxy illusion: destination appears as hop 1 with near-zero RTT.
    if ($toDest -and $avg -ge 0 -and $avg -le 8) { return $true }
    if ($real.Count -eq 1 -and $toDest) { return $true }
    return $false
}

function Show-PathUnavailableScreen {
    param([string]$Reason, [string]$Target = $null)
    [Console]::Clear()
    [Console]::CursorVisible = $false
    Write-Host ""
    Write-Host " YT-DPI PATH — недоступно" -ForegroundColor Yellow
    Write-Host (" " + ("-" * 60)) -ForegroundColor DarkGray
    Write-Host ""
    if ($Target) {
        Write-Host (" Цель: {0}" -f $Target) -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host (" {0}" -f $Reason) -ForegroundColor White
    Write-Host ""
    Write-Host " ICMP TTL не идёт через HTTP/SOCKS-прокси и часто врёт" -ForegroundColor DarkGray
    Write-Host " внутри туннеля VPN (ложный «прямой» маршрут)." -ForegroundColor DarkGray
    Write-Host " Для диагностики DPI используйте обычный Enter-скан таблицы." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host " Esc/Enter — назад" -ForegroundColor DarkGray
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true).Key
            if ($k -in @("Enter", "Escape", "Spacebar", "G")) { break }
        }
        Start-Sleep -Milliseconds 40
    }
}

function Show-PathProbeScreen {
    param([string]$Target, $Hops, [string]$Note = $null)
    [Console]::Clear()
    [Console]::CursorVisible = $false
    $w = [Console]::WindowWidth
    if ($w -gt 100) { $w = 100 }
    $gw = 10
    try { if ($script:Config -and $script:Config.GraphWidth) { $gw = [int]$script:Config.GraphWidth } } catch { }
    if ($gw -lt 4) { $gw = 4 }
    if ($gw -gt 24) { $gw = 24 }
    Write-Host ""
    Write-Host (" YT-DPI PATH (ICMP TTL) -> {0}" -f $Target) -ForegroundColor Cyan
    Write-Host (" {0}" -f ("-" * [Math]::Min(78, $w - 2))) -ForegroundColor DarkGray
    if ($Note) {
        Write-Host (" ! {0}" -f $Note) -ForegroundColor Yellow
        Write-Host (" {0}" -f ("-" * [Math]::Min(78, $w - 2))) -ForegroundColor DarkGray
    }
    Write-Host (" {0,-4} {1,-16} {2,5} {3,5} {4,5} {5,5}  {6}" -f "Hop", "IP", "Loss", "Last", "Avg", "Best", "RTT") -ForegroundColor White
    $maxAvg = 1.0
    foreach ($h in @($Hops)) {
        if ($null -ne $h.Avg -and $h.Avg -gt $maxAvg) { $maxAvg = [double]$h.Avg }
    }
    # Ratio fill vs max hop Avg (not sparkline of 1–3 samples stretched to width — that looked solid-full).
    $fullCh = "#"
    $emptyCh = "."
    try {
        $mode = "Blocks"
        if ($script:Config -and $script:Config.GraphCharset) { $mode = [string]$script:Config.GraphCharset }
        if ($mode -ne "Ascii") {
            $fullCh = [string]([char]0x2588)
            $emptyCh = " "
        }
    } catch { }
    $scale = [Math]::Max($maxAvg * 1.15, $maxAvg + 1)
    foreach ($h in @($Hops)) {
        $ip = if ($h.Ip) { $h.Ip } else { "*" }
        $loss = ("{0}%" -f $h.LossPct)
        $last = if ($null -ne $h.Last) { $h.Last } else { "-" }
        $avg = if ($null -ne $h.Avg) { $h.Avg } else { "-" }
        $best = if ($null -ne $h.Best) { $h.Best } else { "-" }
        $spark = (" " * $gw)
        if ($null -ne $h.Avg -and [double]$h.Avg -gt 0) {
            $ratio = [double]$h.Avg / $scale
            if ($ratio -gt 1) { $ratio = 1 }
            $filled = [int][Math]::Floor($ratio * $gw + 0.0001)
            if ($filled -lt 1) { $filled = 1 }
            if ($filled -gt $gw) { $filled = $gw }
            $spark = ($fullCh * $filled) + ($emptyCh * ($gw - $filled))
        }
        $fg = "Gray"
        if ($h.Status -eq "DONE") { $fg = "Green" }
        elseif ($h.Status -eq "TCP443") { $fg = "Cyan" }
        elseif ($h.LossPct -ge 50) { $fg = "Yellow" }
        elseif ($h.Status -eq "TIMEOUT") { $fg = "DarkGray" }
        $hopLabel = if ($h.Hop -eq 0) { "TCP" } else { $h.Hop }
        Write-Host (" {0,-4} {1,-16} {2,5} {3,5} {4,5} {5,5}  {6}" -f $hopLabel, $ip, $loss, $last, $avg, $best, $spark) -ForegroundColor $fg
    }
    Write-Host ""
    Write-Host " Esc/Enter - back to table (ICMP only; Deep Trace removed)" -ForegroundColor DarkGray
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true).Key
            if ($k -in @("Enter", "Escape", "Spacebar", "G")) { break }
        }
        Start-Sleep -Milliseconds 40
    }
}

function Invoke-PathScanAction {
    Write-DebugLog "PATH mtr-lite [G]"
    $row = Get-FeedbackRow -count $(if ($script:Targets) { $script:Targets.Count } else { 0 })
    Write-StatusLine -Row $row -Message "" -Fg "White" -Bg "Black"

    $block = Get-PathProbeBlockReason
    if ($block) {
        Write-DebugLog "PATH blocked: $block" "INFO"
        Show-PathUnavailableScreen -Reason $block
        Restore-MainUiConsole
        Update-ConsoleSize
        Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    if (-not $script:Targets -or $script:Targets.Count -eq 0) {
        Write-StatusLine -Row $row -Message "[ PATH ] Нет целей" -Fg "White" -Bg "DarkRed"
        Start-Sleep -Seconds 2
        Draw-StatusBar
        return
    }
    $promptMsg = "[ PATH ] № домена (1..$($script:Targets.Count), Enter=CDN): "
    $input = Read-StatusBarNumberInput -Row $row -Prompt $promptMsg
    $row = Get-FeedbackRow -count $script:Targets.Count
    [Console]::CursorVisible = $false
    $target = $null
    $idx = 0
    if ([string]::IsNullOrWhiteSpace($input)) {
        try {
            if ($script:NetInfo -and $script:NetInfo.CDN) { $target = [string]$script:NetInfo.CDN }
        } catch { }
        if (-not $target) { $target = [string]$script:Targets[0] }
    } elseif ([int]::TryParse($input, [ref]$idx) -and $idx -ge 1 -and $idx -le $script:Targets.Count) {
        $target = [string]$script:Targets[$idx - 1]
    } else {
        Write-StatusLine -Row $row -Message "[ PATH ] Неверный номер" -Fg "White" -Bg "DarkRed"
        Start-Sleep -Seconds 2
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    $block2 = Get-PathProbeBlockReason
    if ($block2) {
        Show-PathUnavailableScreen -Reason $block2 -Target $target
        Restore-MainUiConsole
        Update-ConsoleSize
        Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    $maxHops = 15; $samples = 3; $interval = 200
    try { if ($script:Config.PathMaxHops) { $maxHops = [int]$script:Config.PathMaxHops } } catch { }
    try { if ($script:Config.PathSamples) { $samples = [int]$script:Config.PathSamples } } catch { }
    try { if ($script:Config.PathIntervalMs) { $interval = [int]$script:Config.PathIntervalMs } } catch { }
    Write-StatusLine -Row $row -Message "[ PATH ] Зонд $target (ICMP TTL, Esc — отмена)..." -Fg "White" -Bg "DarkCyan"
    $hops = @()
    try {
        $hops = @(Invoke-IcmpTtlPathProbe -Target $target -MaxHops $maxHops -Samples $samples -IntervalMs $interval -OnProgress {
                param($hop, $all)
                $rr = Get-FeedbackRow -count $script:Targets.Count
                $msg = "[ PATH ] hop $($hop.Hop)/$maxHops $($hop.Ip) loss=$($hop.LossPct)%"
                Write-StatusLine -Row $rr -Message $msg -Fg "White" -Bg "DarkCyan"
            })
    } catch {
        Write-DebugLog "PATH probe: $_" "ERROR"
        Write-StatusLine -Row $row -Message ("[ PATH ] Ошибка: {0}" -f $_.Exception.Message) -Fg "White" -Bg "DarkRed"
        Start-Sleep -Seconds 3
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    $destIp = $null
    try {
        $destIp = ([System.Net.Dns]::GetHostAddresses($target) |
            Where-Object { $_.AddressFamily -eq "InterNetwork" } |
            Select-Object -First 1).IPAddressToString
    } catch { }

    if (Test-PathHopsCollapsedTunnel -Hops $hops -DestIp $destIp) {
        Write-DebugLog "PATH collapsed tunnel-like result for $target" "INFO"
        Show-PathUnavailableScreen -Target $target -Reason "Трасса схлопнулась (1 hop / ~0 ms до цели) — похоже на VPN или прозрачный туннель. ICMP PATH здесь неинформативен."
        Restore-MainUiConsole
        Update-ConsoleSize
        Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    Show-PathProbeScreen -Target $target -Hops $hops
    Restore-MainUiConsole
    Update-ConsoleSize
    Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
    Draw-StatusBar
    Clear-KeyBuffer
}

function Invoke-ExtraViewAction {
    Write-DebugLog "EXTRA full view [E]"
    [Console]::Clear()
    [Console]::CursorVisible = $false
    Write-Host ""
    Write-Host " YT-DPI доп. диагностика" -ForegroundColor Cyan
    Write-Host (" " + ("-" * 60)) -ForegroundColor DarkGray
    if (Get-Command Format-ExtraDiagText -ErrorAction SilentlyContinue) {
        $txt = Format-ExtraDiagText
        $hasBody = $false
        foreach ($line in ($txt -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { Write-Host ""; continue }
            Write-Host (" " + $line) -ForegroundColor Gray
            $hasBody = $true
        }
        if (-not $hasBody) {
            Write-Host " (данных ещё нет — сначала выполните скан Enter)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host " (данных ещё нет — сначала выполните скан Enter)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host " Esc/Enter — назад" -ForegroundColor DarkGray
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true).Key
            if ($k -in @("Enter", "Escape", "Spacebar", "E")) { break }
        }
        Start-Sleep -Milliseconds 40
    }
    Restore-MainUiConsole
    Update-ConsoleSize
    Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
    Draw-StatusBar
    Clear-KeyBuffer
}

function Clear-KeyBuffer {
    while ([Console]::KeyAvailable) {
        $null = [Console]::ReadKey($true)
    }
}

function Read-MenuKeyOrResize {
    while ($true) {
        [Console]::CursorVisible = $false
        if (Test-UiConsoleLayoutChanged) {
            return [PSCustomObject]@{ Resized = $true; Key = $null; KeyChar = [char]0 }
        }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            return [PSCustomObject]@{ Resized = $false; Key = $k.Key; KeyChar = $k.KeyChar }
        }
        Start-Sleep -Milliseconds 50
    }
}

function Read-MenuLineOrResize {
    param([string]$Prompt = "")

    $value = ""
    [Console]::CursorVisible = $false
    while ($true) {
        if (Test-UiConsoleLayoutChanged) {
            return [PSCustomObject]@{ Resized = $true; Text = $value; Cancelled = $false }
        }
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $key = [Console]::ReadKey($true)
        if ($key.Key -eq "Enter") {
            return [PSCustomObject]@{ Resized = $false; Text = $value; Cancelled = $false }
        }
        elseif ($key.Key -eq "Escape") {
            return [PSCustomObject]@{ Resized = $false; Text = ""; Cancelled = $true }
        }
        elseif ($key.Key -eq "Backspace") {
            if ($value.Length -gt 0) {
                $value = $value.Substring(0, $value.Length - 1)
                [Console]::Write("`b `b")
            }
        }
        elseif (-not [char]::IsControl($key.KeyChar)) {
            $value += [string]$key.KeyChar
            [Console]::Write($key.KeyChar)
        }
    }
}

function Update-ConsoleSize {
    try {
        [Console]::CursorVisible = $false
        try { [Console]::CursorSize = 1 } catch { }
        try { [Console]::SetCursorPosition(0, 0) } catch { }
        # Do not grow window to fit all targets — table uses a scroll viewport.
        $h = 30
        try { $h = [Console]::WindowHeight } catch { }
        if ($h -lt 8) { $h = 8 }
        $maxHeight = [Console]::LargestWindowHeight
        if ($h -gt $maxHeight) { $h = $maxHeight }
        $script:Truncated = $false
        try {
            $layout = Get-UiLayout -TargetCount $(if ($script:Targets) { $script:Targets.Count } else { 0 })
            if ($layout.MaxScroll -gt 0) { $script:Truncated = $true }
        } catch { }

        $w = if ($script:DesiredConsoleWidth) { [int]$script:DesiredConsoleWidth } else { 135 }
        $maxWidth = [Console]::LargestWindowWidth
        if ($w -gt $maxWidth) { $w = $maxWidth }

        try {
            if ($script:CurrentWindowHeight -le 0 -or $script:CurrentWindowWidth -le 0) {
                [Console]::BufferWidth = $w
                [Console]::WindowWidth = $w
                [Console]::WindowHeight = $h
                [Console]::BufferWidth = $w
                [Console]::BufferHeight = $h
                $script:CurrentWindowWidth = $w
                $script:CurrentWindowHeight = $h
            }
            else {
                $cw = [Console]::WindowWidth
                $ch = [Console]::WindowHeight
                if ([Console]::BufferWidth -lt $cw) { [Console]::BufferWidth = $cw }
                if ([Console]::BufferHeight -lt $ch) { [Console]::BufferHeight = $ch }
                $script:CurrentWindowWidth = $cw
                $script:CurrentWindowHeight = $ch
            }
        } catch {
            Write-DebugLog "Не удалось изменить размер окна: $_"
        }
    } catch {}
}

function Sync-DynamicColPosFromLayout {
    $ipW = if ($script:IpColumnWidth) { $script:IpColumnWidth } else { 16 }
    $domStart = 6
    $ipStart = $domStart + 42 + 2
    $httpStart = $ipStart + $ipW + 2
    $t12Start = $httpStart + 6 + 2
    $t13Start = $t12Start + 8 + 2
    $latStart = $t13Start + 8 + 2
    $verStart = $latStart + 12 + 2
    $script:DynamicColPos = @{
        Num  = 1
        Dom  = $domStart
        IP   = $ipStart
        HTTP = $httpStart
        T12  = $t12Start
        T13  = $t13Start
        Lat  = $latStart
        Ver  = $verStart
    }
}

function Update-UiConsoleSnapshot {
    try {
        $script:UiLayoutWidth = [Console]::WindowWidth
        $script:UiLayoutHeight = [Console]::WindowHeight
    } catch {}
}

function Test-UiConsoleLayoutChanged {
    try {
        if ($null -eq $script:UiLayoutWidth) { return $false }
        return ([Console]::WindowWidth -ne $script:UiLayoutWidth -or
                [Console]::WindowHeight -ne $script:UiLayoutHeight)
    } catch { return $false }
}

function Get-UiResizeDebounceMs {
    if ($CONST.UiScan -and $null -ne $CONST.UiScan.ResizeDebounceMs) {
        return [int]$CONST.UiScan.ResizeDebounceMs
    }
    return 180
}

# Returns $true once size has been stable for ResizeDebounceMs after a change.
function Test-UiConsoleResizeSettled {
    try {
        $cw = [Console]::WindowWidth
        $ch = [Console]::WindowHeight
        if ($null -eq $script:UiLayoutWidth -or $null -eq $script:UiLayoutHeight) {
            Update-UiConsoleSnapshot
            $script:ResizePendingSince = $null
            return $false
        }
        $changed = ($cw -ne $script:UiLayoutWidth -or $ch -ne $script:UiLayoutHeight)
        if (-not $changed) {
            if ($null -eq $script:ResizePendingSince) { return $false }
            # Size matched snapshot again mid-debounce — still wait until pending settles to new size
        }
        $now = [Environment]::TickCount64
        $debounce = Get-UiResizeDebounceMs
        if ($null -eq $script:ResizePendingSince -or
            $cw -ne $script:ResizePendingW -or $ch -ne $script:ResizePendingH) {
            $script:ResizePendingSince = $now
            $script:ResizePendingW = $cw
            $script:ResizePendingH = $ch
            return $false
        }
        if (($now - $script:ResizePendingSince) -lt $debounce) { return $false }
        if ($cw -eq $script:UiLayoutWidth -and $ch -eq $script:UiLayoutHeight) {
            $script:ResizePendingSince = $null
            return $false
        }
        return $true
    } catch { return $false }
}

# Во время скана сравниваем с локальным снимком и порогом >1 колонка/строка — иначе дребезг
# WindowWidth/Height даёт ложные «ресайзы» и полный Draw-UI на каждом тике статус-бара.
function Test-ScanPhaseConsoleLayoutChanged {
    try {
        if ($null -ne $script:ScanLayoutSnapW -and $null -ne $script:ScanLayoutSnapH) {
            $cw = [Console]::WindowWidth
            $ch = [Console]::WindowHeight
            $dw = [Math]::Abs($cw - $script:ScanLayoutSnapW)
            $dh = [Math]::Abs($ch - $script:ScanLayoutSnapH)
            if ($dw -le 1 -and $dh -le 1) {
                $script:ResizePendingSince = $null
                return $false
            }
            return (Test-UiConsoleResizeSettled)
        }
        return (Test-UiConsoleResizeSettled)
    } catch { return $false }
}

function Invoke-FullUiRedrawIfConsoleResized {
    param([switch]$Force)
    if (-not $Force) {
        if (-not (Test-UiConsoleResizeSettled)) { return $false }
    } else {
        if (-not (Test-UiConsoleLayoutChanged)) { return $false }
    }
    Write-DebugLog "Изменён размер консоли — полная перерисовка UI (Force=$Force)" "INFO"
    $script:ResizePendingSince = $null
    Restore-MainUiConsole
    Update-ConsoleSize
    $null = Clamp-TableScroll
    $scanRows = $null
    if ($script:LastScanResults -and $script:Targets -and $script:LastScanResults.Count -eq $script:Targets.Count) {
        $scanRows = $script:LastScanResults
    }
    if ($scanRows) { Update-LatBarScale -Results $scanRows }
    Draw-UI $script:NetInfo $script:Targets $scanRows $true
    Sync-DynamicColPosFromLayout
    Clear-StatusBlock
    Draw-StatusBar
    Update-UiConsoleSnapshot
    return $true
}

function Invoke-ScanRedrawIfConsoleResized {
    param(
        [object[]]$LiveResults,
        [array]$Targets,
        [string]$StatusBarMessage = $null,
        [double]$Progress = -1
    )
    $resized = Test-ScanPhaseConsoleLayoutChanged
    if ($resized) {
        Write-DebugLog "Ресайз во время скана — полная перерисовка (Clear)" "INFO"
        $script:ResizePendingSince = $null
        Update-ConsoleSize
        $null = Clamp-TableScroll -TargetCount $(if ($Targets) { $Targets.Count } else { 0 })
        if ($LiveResults) { Update-LatBarScale -Results $LiveResults }
        Draw-UI $script:NetInfo $Targets $LiveResults $true
        Sync-DynamicColPosFromLayout
        Clear-StatusBlock
        try {
            $script:ScanLayoutSnapW = [Console]::WindowWidth
            $script:ScanLayoutSnapH = [Console]::WindowHeight
        } catch {}
        Update-UiConsoleSnapshot
    }
    if ($null -ne $Progress -and $Progress -ge 0) {
        $msg = if ($StatusBarMessage) { $StatusBarMessage } else { "[ SCAN ]" }
        Draw-StatusBar -Message $msg -Fg "Black" -Bg "Green" -Progress $Progress
        Update-UiConsoleSnapshot
    }
    elseif ($resized) {
        if ($StatusBarMessage) {
            Draw-StatusBar -Message $StatusBarMessage -Fg "Black" -Bg "Green"
        } else {
            Draw-StatusBar
        }
        Update-UiConsoleSnapshot
    }
}

function Read-MainLoopKey {
    $pollMs = 20
    while ($true) {
        if ($null -ne $script:PendingMainKey) {
            $pk = $script:PendingMainKey
            $script:PendingMainKey = $null
            return $pk
        }
        if ($script:UiCursorHidden -ne $true) {
            [Console]::CursorVisible = $false
            $script:UiCursorHidden = $true
        }
        try { [Console]::CursorSize = 1 } catch { }
        if (Test-UiConsoleResizeSettled) {
            $null = Invoke-FullUiRedrawIfConsoleResized
        }
        elseif (Test-UiConsoleLayoutChanged) {
            # Size changed but debounce not settled — keep polling without redraw spam
            $null = Test-UiConsoleResizeSettled
        }
        if ([Console]::KeyAvailable) {
            return [Console]::ReadKey($true).Key
        }
        # Prefer keys over EXTRA: poll async EXTRA; never run probes on the UI thread.
        if ($script:ExtrasPending -and $script:ScanPhase -eq "Idle") {
            if (Update-ExtrasFromCompletedAsync) { continue }
        }
        $nowNet = [Environment]::TickCount64
        if ($null -eq $script:_netInfoPollMs) { $script:_netInfoPollMs = $nowNet }
        if (($nowNet - $script:_netInfoPollMs) -ge 1000) {
            $script:_netInfoPollMs = $nowNet
            Update-NetInfoFromCompletedJob
        }
        Start-Sleep -Milliseconds $pollMs
    }
}

function Get-ControlsRow {
    param([int]$count)
    try {
        $layout = Get-UiLayout -TargetCount $count
        return [int]$layout.NavRow
    } catch {
        return 9 + 3 + $count + 2
    }
}

function Get-FeedbackRow {
    param([int]$count)
    try {
        $layout = Get-UiLayout -TargetCount $count
        return [int]$layout.FeedbackRow
    } catch {
        return (Get-ControlsRow -count $count) + 1
    }
}

function Get-NavRow {
    param([int]$count)
    return Get-ControlsRow -count $count
}

function Write-StatusLine {
    param(
        [int]$Row,
        [string]$Message,
        [string]$Fg = "White",
        [string]$Bg = "Black",
        [int]$X = 2
    )
    if ($Row -lt 0 -or $Row -ge [Console]::BufferHeight) { return }

    $width = [Console]::WindowWidth
    $text = [string]$Message

    if ($script:Targets) {
        $controlsText = ([string]$CONST.NavStr) -replace '^\[READY\]\s*', ''
        $navLine = " $controlsText "
        if ($navLine.Length -gt $width) { $navLine = $navLine.Substring(0, [Math]::Max(0, $width - 3)) + "..." }
        $barX = [Math]::Max(0, [Math]::Floor(($width - $navLine.Length) / 2))
        $barWidth = $navLine.Length

        if ([string]::IsNullOrWhiteSpace($text)) {
            Out-Str $barX $Row (" " * $barWidth) "Black" "Black"
            Reset-StatusBarCache
            return
        }

        if ($text.Length -gt ($barWidth - 2)) {
            $text = $text.Substring(0, [Math]::Max(0, $barWidth - 5)) + "..."
        }
        $line = Format-CellCenter $text $barWidth
        $statusKey = "manual|$Row|$barX|Black|Green|$line"
        if ($script:StatusFeedbackCacheKey -ne $statusKey) {
            Out-Str $barX $Row $line "Black" "Green"
            $script:StatusFeedbackCacheKey = $statusKey
        }
        return
    }

    Out-Str 0 $Row (" " * $width) "Black" "Black"
    $maxTextWidth = [Math]::Max(0, $width - $X)
    if ($maxTextWidth -le 0) { return }
    if ($text.Length -gt $maxTextWidth) { $text = $text.Substring(0, [Math]::Max(0, $maxTextWidth - 3)) + "..." }
    Out-Str $X $Row ($text.PadRight($maxTextWidth)) "Black" "Green"
    Reset-StatusBarCache
}

function Read-StatusBarNumberInput {
    param(
        [int]$Row,
        [string]$Prompt
    )

    $inputText = ""
    $currentRow = $Row
    while ($true) {
        if (Test-UiConsoleResizeSettled) {
            $null = Invoke-FullUiRedrawIfConsoleResized
            $currentRow = Get-FeedbackRow -count $script:Targets.Count
        }
        elseif (Test-UiConsoleLayoutChanged) {
            $null = Test-UiConsoleResizeSettled
        }

        Write-StatusLine -Row $currentRow -Message ($Prompt + $inputText) -Fg "Black" -Bg "Green"
        [Console]::CursorVisible = $false

        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $key = [Console]::ReadKey($true)
        if ($key.Key -in @("Enter", "Escape")) {
            if ($key.Key -eq "Escape") { return "" }
            return $inputText
        }
        elseif ($key.Key -eq "Backspace") {
            if ($inputText.Length -gt 0) {
                $inputText = $inputText.Substring(0, $inputText.Length - 1)
            }
        }
        elseif ($key.KeyChar -ge '0' -and $key.KeyChar -le '9') {
            $inputText += [string]$key.KeyChar
        }
    }
}

function Reset-StatusBarCache {
    $script:StatusFeedbackCacheKey = $null
    $script:StatusControlsCacheKey = $null
    $script:StatusBarLayoutW = $null
}

function Restore-MainUiConsole {
    # After full-screen menus the buffer may be scrolled; reset viewport without
    # forcibly shrinking BufferHeight (that clipped table/ExtraStrip and broke bars).
    # Do NOT zero CurrentWindowWidth/Height — that would re-force Window size via Update-ConsoleSize.
    try {
        try {
            $raw = $Host.UI.RawUI
            $raw.WindowPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0
            $raw.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0
        } catch {
            try { [Console]::SetCursorPosition(0, 0) } catch { }
        }
        try {
            $script:CurrentWindowWidth = [Console]::WindowWidth
            $script:CurrentWindowHeight = [Console]::WindowHeight
        } catch { }
    } catch {
        Write-DebugLog "Restore-MainUiConsole: $_" "WARN"
    }
    Reset-StatusBarCache
    $script:StatusBarLayoutW = $null
    $script:ResizePendingSince = $null
    $script:UiCursorHidden = $false
}

function Clear-StatusBlock {
    if (-not $script:Targets) { return }
    $width = [Console]::WindowWidth
    $feedbackRow = Get-FeedbackRow -count $script:Targets.Count
    $controlsRow = Get-ControlsRow -count $script:Targets.Count
    Out-Str 0 $feedbackRow (" " * $width) "Black" "Black"
    Out-Str 0 $controlsRow (" " * $width) "Black" "Black"
    Reset-StatusBarCache
}

function Get-IdleStatusMessage {
    if (-not $script:HasCompletedScan -or -not $script:LastScanResults -or $script:LastScanResults.Count -lt 1) {
        return [PSCustomObject]@{ Text = "STATUS: ГОТОВ"; Fg = "Black"; Bg = "Green" }
    }

    $available = 0; $throttled = 0; $dpi = 0; $ipBlock = 0
    $timeout = 0; $unknown = 0; $aborted = 0; $rows = 0
    foreach ($r in $script:LastScanResults) {
        if (-not $r) { continue }
        $rows++
        switch ([string]$r.Verdict) {
            "AVAILABLE" { $available++; break }
            "THROTTLED" { $throttled++; break }
            "DPI RESET" { $dpi++; break }
            "DPI BLOCK" { $dpi++; break }
            "IP BLOCK" { $ipBlock++; break }
            "TIMEOUT" { $timeout++; break }
            "UNKNOWN" { $unknown++; break }
            "SCAN ABORTED" { $aborted++; break }
        }
    }
    if ($rows -lt 1) {
        return [PSCustomObject]@{ Text = "STATUS: ГОТОВ"; Fg = "Black"; Bg = "Green" }
    }

    if ($aborted -eq $rows) {
        return [PSCustomObject]@{ Text = "STATUS: SCAN ABORTED"; Fg = "Black"; Bg = "Yellow" }
    }

    if ($available -eq $rows) {
        return [PSCustomObject]@{ Text = "SCAN RESULT: OK | $available HOSTS AVAILABLE"; Fg = "Black"; Bg = "Green" }
    }

    $parts = @()
   # if ($available -gt 0) { $parts += "$available AVAILABLE" } # пока пишем только заблоченные
    if ($throttled -gt 0) { $parts += "$throttled THROTTLED" }
    if ($dpi -gt 0) { $parts += "$dpi DPI BLOCK/RESET" }
    if ($ipBlock -gt 0) { $parts += "$ipBlock IP BLOCK" }
    if ($timeout -gt 0) { $parts += "$timeout TIMEOUT" }
    if ($unknown -gt 0) { $parts += "$unknown UNKNOWN" }
    if ($aborted -gt 0) { $parts += "$aborted ABORTED" }

    if ($parts.Count -eq 0) {
        return [PSCustomObject]@{ Text = "STATUS: ГОТОВ"; Fg = "Black"; Bg = "Green" }
    }

    return [PSCustomObject]@{
        Text = "SCAN RESULT: DPI DETECTED | " + ($parts -join " | ")
        Fg = "Black"
        Bg = "Yellow"
    }
}

function Draw-StatusBar {
    param(
        [string]$Message = $null,
        [string]$Fg = "Black",
        [string]$Bg = "Green",
        [double]$Progress = -1
    )
    if (-not $script:Targets) { return }
    [Console]::CursorVisible = $false
    $feedbackRow = Get-FeedbackRow -count $script:Targets.Count
    $controlsRow = Get-ControlsRow -count $script:Targets.Count
    $width = [Console]::WindowWidth

    # Full-width wipe when window width changes — kills green bar tails after resize.
    if ($null -eq $script:StatusBarLayoutW -or $script:StatusBarLayoutW -ne $width) {
        Out-Str 0 $feedbackRow (" " * $width) "Black" "Black"
        Out-Str 0 $controlsRow (" " * $width) "Black" "Black"
        Reset-StatusBarCache
        $script:StatusBarLayoutW = $width
    }

    $controlsText = ([string]$CONST.NavStr) -replace '^\[READY\]\s*', ''
    $navLine = " $controlsText "
    if ($navLine.Length -gt $width) { $navLine = $navLine.Substring(0, [Math]::Max(0, $width - 3)) + "..." }
    $navX = [Math]::Max(0, [Math]::Floor(($width - $navLine.Length) / 2))
    $statusWidth = $navLine.Length

    $idleStatus = $null
    if ($Message) {
        $text = $Message
        # Keep caller Fg/Bg (scan progress, one-shot TIP, errors) — do not force Green.
    } else {
        $idleStatus = Get-IdleStatusMessage
        $text = $idleStatus.Text
        $Fg = $idleStatus.Fg
        $Bg = $idleStatus.Bg
    }

    # Полоска прогресса 0..1 в правой части строки (во время скана)
    $tail = ""
    if ($null -ne $Progress -and $Progress -ge 0) {
        $p = [double]$Progress
        if ($p -gt 1) { $p = 1 }
        if ($p -lt 0) { $p = 0 }
        $barW = [Math]::Min(18, [Math]::Max(8, $width / 8))
        $filled = [int][Math]::Floor($p * $barW + 0.001)
        if ($filled -gt $barW) { $filled = $barW }
        $tail = " [" + ("=" * $filled) + ("-" * ($barW - $filled)) + "] " + ([int]($p * 100)).ToString() + "%"
        $reserve = $tail.Length + 2
        $maxMsg = [Math]::Max(12, $statusWidth - 2 - $reserve)
        if ($text.Length -gt $maxMsg) { $text = $text.Substring(0, $maxMsg - 3) + "..." }
    }
    else {
        if ($text.Length -gt ($statusWidth - 2)) { $text = $text.Substring(0, [Math]::Max(0, $statusWidth - 5)) + "..." }
    }

    if ($text -or $tail) {
        $line = " $text$tail "
        if ($line.Length -gt $statusWidth) { $line = $line.Substring(0, $statusWidth) }
        $line = Format-CellCenter $line.Trim() $statusWidth
        $feedbackKey = "$feedbackRow|$navX|$Fg|$Bg|$line"
        if ($script:StatusFeedbackCacheKey -ne $feedbackKey) {
            Out-Str $navX $feedbackRow $line $Fg $Bg
            $script:StatusFeedbackCacheKey = $feedbackKey
        }
    }

    $controlsKey = "$controlsRow|$navX|Black|Green|$navLine"
    if ($script:StatusControlsCacheKey -ne $controlsKey) {
        Out-Str $navX $controlsRow $navLine "Black" "Green"
        $script:StatusControlsCacheKey = $controlsKey
    }
}

function Update-NetInfoPanel {
    param($NetInfo)
    if ($null -eq $NetInfo) { return }

    $rightW = [Math]::Max(20, [Console]::WindowWidth - 66)
    Out-Str 65 3 (Format-CellLeft ("> LOCAL DNS: " + $NetInfo.DNS) $rightW) "Cyan"
    Out-Str 65 4 (Format-CellLeft ("> CDN NODE: " + $NetInfo.CDN) $rightW) "Yellow"

    $dispIsp = [string]$NetInfo.ISP
    if ($dispIsp.Length -gt 35) { $dispIsp = $dispIsp.Substring(0, 32) + "..." }
    $dispLoc = [string]$NetInfo.LOC
    if ($dispLoc.Length -gt 30) { $dispLoc = $dispLoc.Substring(0, 27) + "..." }
    Out-Str 65 6 (Format-CellLeft ("> ISP / LOC: $dispIsp ($dispLoc)") $rightW) "Magenta"
}

function Initialize-ScannerEngines {
    $needTls = (-not (Test-TlsScannerReady)) -and (-not $script:TlsScannerLoadFailed)
    if (-not $needTls) { return }

    Draw-StatusBar -Message "[ ENGINE ] Loading scan engines..." -Fg "Black" -Bg "Yellow"
    $null = Ensure-TlsScannerLoaded
    Draw-StatusBar
}

function Draw-UI ($NetInfo, $Targets, $Results, $ClearScreen = $true) {
    # $Results - массив объектов с результатами сканирования (свойство .IP)
    # ClearScreen=$false: без [Console]::Clear — перерисовка поверх старых ячеек (меньше мигания).
    # Выборочная перерисовка (только одна строка/колонка) пока не вынесена в отдельные API — при изменении
    # данных таблицы без смены числа строк обычно достаточно Draw-UI ... $false.
    Write-DebugLog "Draw-UI: Targets count=$($Targets.Count), ClearScreen=$ClearScreen"

    [Console]::CursorVisible = $false

    # Исторически в третий параметр ошибочно передавали $true/$NeedClear (bool); у скаляра .Count=1 → ломалась только первая строка таблицы
    if ($null -ne $Results -and $Results -is [bool]) { $Results = $null }

        # --- Динамический расчёт ширины колонки IP ---
    $ipColumnWidth = 16

    # 1. Проверяем текущие результаты (если они есть)
    if ($Results) {
        $maxIpLen = ($Results | ForEach-Object { if ($_.IP) { $_.IP.ToString().Length } else { 0 } } | Measure-Object -Maximum).Maximum
        if ($maxIpLen -gt $ipColumnWidth) { $ipColumnWidth = $maxIpLen + 2 }
    }

    # 2. Проверяем DNS-кэш (чтобы заранее знать про длинные IPv6)
    if ($script:DnsCache) {
        $cacheIpMax = ($script:DnsCache.Values | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        if ($cacheIpMax -gt $ipColumnWidth) { $ipColumnWidth = $cacheIpMax + 2 }
    }

    if ($ipColumnWidth -gt 45) { $ipColumnWidth = 45 }
    $script:IpColumnWidth = $ipColumnWidth

    # --- Пересчёт позиций колонок (остальные ширины фиксированы) ---
    $domStart  = 6
    $domWidth  = 42
    $ipStart   = $domStart + $domWidth + 2   # позиция после колонки Domain с отступом
    $ipWidth   = $ipColumnWidth
    $httpStart = $ipStart + $ipWidth + 2
    $httpWidth = 6
    $t12Start  = $httpStart + $httpWidth + 2
    $t12Width  = 8
    $t13Start  = $t12Start + $t12Width + 2
    $t13Width  = 8
    $latStart  = $t13Start + $t13Width + 2
    $latWidth  = 12
    $verStart  = $latStart + $latWidth + 2
    $verWidth  = 18
    $script:DesiredConsoleWidth = [Math]::Max(122, $verStart + $verWidth + 1)

    Update-ConsoleSize
    if ($ClearScreen) {
        try {
            $raw = $Host.UI.RawUI
            $raw.WindowPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0
        } catch { }
        try { [Console]::SetCursorPosition(0, 0) } catch { }
        [Console]::Clear()
        Reset-StatusBarCache
    }

    # YT-DPI-LOGO-BEGIN (между BEGIN/END — только вызовы Out-Str; tools/logo.ps1 и tools/logo.bat подхватывают этот блок)
    Out-Str 1 1 ' ██╗   ██╗████████╗    ██████╗ ██████╗ ██╗' 'Green'
    Out-Str 1 2 ' ╚██╗ ██╔╝╚══██╔══╝    ██╔══██╗██╔══██╗██║' 'Green'
    Out-Str 1 3 '  ╚████╔╝    ██║ █████╗██║  ██║██████╔╝██║' 'Green'
    Out-Str 1 4 '   ╚██╔╝     ██║ ╚════╝██║  ██║██╔═══╝ ██║' 'Green'
    Out-Str 1 5 '    ██║      ██║       ██████║ ██║     ██║' 'Green'
    Out-Str 1 6 '    ╚═╝      ╚═╝       ╚═════╝ ╚═╝     ╚═╝' 'Green'

    Out-Str 45 1 '██████╗     ██████╗ ' 'Gray'
    Out-Str 45 2 '╚════██╗   ██╔═══██╗' 'Gray'
    Out-Str 45 3 ' █████╔╝   ██║   ██║' 'Gray'
    Out-Str 45 4 ' ╚═══██╗   ██║   ██║' 'Gray'
    Out-Str 45 5 '██████╔╝██╗╚██████╔╝' 'Gray'
    Out-Str 45 6 '╚═════╝ ╚═╝ ╚═════╝ ' 'Gray'
    # YT-DPI-LOGO-END
    
    $rightW = [Math]::Max(20, [Console]::WindowWidth - 66)
    $statusY = 1
    $statusX0 = 65
    if (Test-DebugLogEnabled) {
        $px = $statusX0
        $rem = $rightW
        $prefix = "> SYS STATUS: "
        $badge = "[ DEBUG ]"
        if ($rem -gt 0) {
            $pl = [Math]::Min($rem, $prefix.Length)
            $prefPart = if ($pl -eq $prefix.Length) { $prefix } else { $prefix.Substring(0, $pl) }
            Out-Str $px $statusY (Format-CellLeft $prefPart $pl) "Green" "Black"
            $px += $pl
            $rem -= $pl
        }
        if ($rem -gt 0) {
            $bl = [Math]::Min($rem, $badge.Length)
            $badgePart = if ($bl -eq $badge.Length) { $badge } else { $badge.Substring(0, $bl) }
            Out-Str $px $statusY $badgePart "White" "Red"
            $px += $bl
            $rem -= $bl
        }
        if ($rem -gt 0) {
            $tail = Get-DebugHudTail -maxLen $rem
            Out-Str $px $statusY (Format-CellLeft $tail $rem) "Green" "Black"
        }
    } else {
        Out-Str $statusX0 $statusY (Format-CellLeft "> SYS STATUS: [ ONLINE ]" $rightW) "Green"
    }
    Out-Str 65 2 (Format-CellLeft "> ENGINE: Barebuh Pro v3.2 / TUI v1.5.3" $rightW) "Red"
    Out-Str 65 3 (Format-CellLeft ("> LOCAL DNS: " + $NetInfo.DNS) $rightW) "Cyan"
    Out-Str 65 4 (Format-CellLeft ("> CDN NODE: " + $NetInfo.CDN) $rightW) "Yellow"
    Out-Str 65 5 (Format-CellLeft "> AUTHOR: github.com/Shiperoid" $rightW) "Green"

    $dispIsp = $NetInfo.ISP
    if ($dispIsp.Length -gt 35) { $dispIsp = $dispIsp.Substring(0, 32) + "..." }
    $dispLoc = $NetInfo.LOC
    if ($dispLoc.Length -gt 30) { $dispLoc = $dispLoc.Substring(0, 27) + "..." }
    $ispStr = "> ISP / LOC: $dispIsp ($dispLoc)"
    Out-Str 65 6 (Format-CellLeft $ispStr $rightW) "Magenta"

    $proxyStatus = if ($global:ProxyConfig.Enabled) { "> PROXY: $($global:ProxyConfig.Type) $($global:ProxyConfig.Host):$($global:ProxyConfig.Port) Connected" } else { "> PROXY: [ OFF ]" }
    Out-Str 65 7 (Format-CellLeft $proxyStatus $rightW) "DarkYellow"
    Out-Str 65 8 (Format-CellLeft "> TG: t.me/YT_DPI | VERSION: $scriptVersion" $rightW) "Green"

    # --- Таблица ---
    $y = 9
    $width = [Console]::WindowWidth

    # Верхняя граница таблицы
    Out-Str 0 $y ("=" * $width) "DarkCyan"

    # Заголовки
    Out-Str 1 ($y+1) (Format-CellCenter "#" 4) "White"
    Out-Str $domStart ($y+1) "TARGET DOMAIN" "White"
    Out-Str $ipStart ($y+1) "IP ADDRESS" "White"
    Out-Str $httpStart ($y+1) (Format-CellCenter "HTTP" $httpWidth) "White"
    Out-Str $t12Start ($y+1) (Format-CellCenter "TLS 1.2" $t12Width) "White"
    Out-Str $t13Start ($y+1) (Format-CellCenter "TLS 1.3" $t13Width) "White"
    Out-Str $latStart ($y+1) (Format-CellCenter "LAT (ms)" $latWidth) "White"
    Out-Str $verStart ($y+1) (Format-CellCenter "RESULT" $verWidth) "White"

    Out-Str 0 ($y+2) ("=" * $width) "DarkCyan"

    # Scale BEFORE rows — otherwise LatBarMaxMs stays 1 and every bar paints solid-full.
    try { if ($Results) { Update-LatBarScale -Results $Results } } catch { }

    $layout = Clamp-TableScroll -TargetCount $Targets.Count
    $off = [int]$script:TableScrollOffset
    $vis = [int]$layout.VisibleRows
    $bodyStart = [int]$layout.TableBodyStart
    $bottomRule = [int]$layout.BottomRuleRow

    # Visible window of targets only (no full-body wipe — avoids flicker; cells are padded).
    $endIdx = [Math]::Min($Targets.Count, $off + $vis) - 1
    for ($i = $off; $i -le $endIdx; $i++) {
        $currentRow = $bodyStart + ($i - $off)
        $num = $i + 1
        $numStr = Format-CellCenter $num.ToString() 4

        Out-Str 1 $currentRow $numStr "Cyan"
        Out-Str $domStart $currentRow ($Targets[$i].PadRight($domWidth).Substring(0, $domWidth)) "Gray"

        $res = $null
        if ($Results -and $i -lt $Results.Count) { $res = $Results[$i] }
        if ($null -eq $res) { $res = New-PlaceholderResultRow -Number $num -Target $Targets[$i] }
        if ($null -ne $res) {
            $ipStr = if ($res.IP) { [string]$res.IP } else { "---" }
            if ($ipStr.Length -gt $ipWidth) { $ipStr = $ipStr.Substring(0, $ipWidth - 2) + ".." }
            Out-Str $ipStart $currentRow $ipStr.PadRight($ipWidth).Substring(0, $ipWidth) "DarkGray"

            $htStr = if ($res.HTTP) { [string]$res.HTTP } else { "---" }
            $hCol = if($htStr -eq "OK") {"Green"} elseif($htStr -eq "---") {"DarkGray"} else {"Red"}
            Out-Str $httpStart $currentRow (Format-CellCenter $htStr $httpWidth) $hCol

            $t12Str = if ($res.T12) { [string]$res.T12 } else { "---" }
            $t12Str = Format-TlsCellDisplay -Cell $t12Str -RstPhase $res.RstPhase12
            $t12Col = if($t12Str -eq "OK") {"Green"} elseif($t12Str -eq "N/A" -or $t12Str -eq "---") {"DarkGray"} else {"Red"}
            Out-Str $t12Start $currentRow (Format-CellCenter $t12Str $t12Width) $t12Col

            $t13Str = if ($res.T13) { [string]$res.T13 } else { "---" }
            $t13Str = Format-TlsCellDisplay -Cell $t13Str -RstPhase $res.RstPhase13
            $t13Col = if($t13Str -eq "OK") {"Green"} elseif($t13Str -eq "N/A" -or $t13Str -eq "---") {"DarkGray"} else {"Red"}
            Out-Str $t13Start $currentRow (Format-CellCenter $t13Str $t13Width) $t13Col

            $latStr = if ($res.Lat) { [string]$res.Lat } else { "---" }
            $latCol = if($latStr -eq "---") {"DarkGray"} else {"Cyan"}
            $latOut = Format-LatCell -LatText $latStr -TotalWidth $latWidth -NumWidth 4 -BarWidth 6
            Out-Str $latStart $currentRow $latOut $latCol

            $verStr = if ($res.Verdict) { [string]$res.Verdict } else { "UNKNOWN" }
            Out-Str $verStart $currentRow (Format-CellCenter $verStr $verWidth) $res.Color
        }
    }

    # Bottom rule + scroll hint (never under NAV/STATUS).
    Update-TableBottomScrollRule -Layout $layout
    # Wipe any leftover lines between bottom rule and NAV (after shrink).
    for ($cy = $bottomRule + 1; $cy -lt [int]$layout.NavRow; $cy++) {
        Out-Str 0 $cy (" " * $width) "Black" "Black"
    }

    [Console]::CursorVisible = $false
    Sync-DynamicColPosFromLayout
    Update-UiConsoleSnapshot
}


function Get-ScanAnim($f, $row) {
    $frames = "[=   ]", "[ =  ]", "[  = ]", "[   =]", "[  = ]", "[ =  ]"
    return $frames[($f + $row) % $frames.Length]
}

function Write-ResultLine {
    param(
        [int]$row = -1,
        $result,
        [switch]$IncludeStaticCells,
        [int]$TargetIndex = -1,
        [switch]$TrustedBodyRow
    )
    if ($TargetIndex -ge 0) {
        $row = Get-TableScreenRow -TargetIndex $TargetIndex
    }
    if ($row -lt 0) { return }
    try {
        if ($row -ge [Console]::WindowHeight) { return }
    } catch {
        if ($row -ge [Console]::BufferHeight) { return }
    }
    # Never paint into sticky footer (skip when caller already clipped to body).
    if (-not $TrustedBodyRow) {
        try {
            $nav = Get-ControlsRow -count $(if ($script:Targets) { $script:Targets.Count } else { 0 })
            if ($row -ge $nav) { return }
        } catch { }
    }

    if ($script:UiCursorHidden -ne $true) {
        [Console]::CursorVisible = $false
        $script:UiCursorHidden = $true
    }
    $pos = if ($script:DynamicColPos) { $script:DynamicColPos } else { $CONST.UI }
    $ipWidth = if ($script:IpColumnWidth) { $script:IpColumnWidth } else { 16 }

    if ($IncludeStaticCells) {
        # Номер и домен стабильны между сканами; обновляем их только при явной полной строке.
        $numStr = if ($result.Number) { $result.Number.ToString() } else { "" }
        Out-Str $pos.Num $row (Format-CellCenter $numStr 4) "Cyan"

        Out-Str $pos.Dom $row $result.Target.PadRight(42).Substring(0, 42) "Gray"
    }

    # IP
    $ipStr = if ($result.IP) { [string]$result.IP } else { "---" }
    if ($ipStr.Length -gt $ipWidth) { $ipStr = $ipStr.Substring(0, $ipWidth - 2) + ".." }
    $ipPadded = $ipStr.PadRight($ipWidth)
    Out-Str $pos.IP $row $ipPadded.Substring(0, $ipWidth) "DarkGray"

    # HTTP
    $htStr = if ($result.HTTP) { [string]$result.HTTP } else { "---" }
    $hCol = if($htStr -eq "OK") {"Green"} elseif($htStr -eq "---") {"DarkGray"} else {"Red"}
    Out-Str $pos.HTTP $row (Format-CellCenter $htStr 6) $hCol

    # TLS 1.2
    $t12Str = if ($result.T12) { [string]$result.T12 } else { "---" }
    $t12Str = Format-TlsCellDisplay -Cell $t12Str -RstPhase $result.RstPhase12
    $t12Col = if($t12Str -eq "OK") {"Green"} elseif($t12Str -eq "N/A" -or $t12Str -eq "---") {"DarkGray"} else {"Red"}
    Out-Str $pos.T12 $row (Format-CellCenter $t12Str 8) $t12Col

    # TLS 1.3
    $t13Str = if ($result.T13) { [string]$result.T13 } else { "---" }
    $t13Str = Format-TlsCellDisplay -Cell $t13Str -RstPhase $result.RstPhase13
    $t13Col = if($t13Str -eq "OK") {"Green"} elseif($t13Str -eq "N/A" -or $t13Str -eq "---") {"DarkGray"} else {"Red"}
    Out-Str $pos.T13 $row (Format-CellCenter $t13Str 8) $t13Col

    # LAT (+ fixed-width bar — digit pad left so sparkline column never shifts)
    $latStr = if ($result.Lat) { [string]$result.Lat } else { "---" }
    $latCol = if($latStr -eq "---") {"DarkGray"} else {"Cyan"}
    $latW = 12
    try {
        if ($script:DynamicColPos -and $script:DynamicColPos.Ver -gt $script:DynamicColPos.Lat) {
            $latW = [Math]::Max(12, $script:DynamicColPos.Ver - $script:DynamicColPos.Lat - 2)
        }
    } catch { }
    $latCell = Format-LatCell -LatText $latStr -TotalWidth $latW -NumWidth 4 -BarWidth 6
    Out-Str $pos.Lat $row $latCell $latCol

    # VERDICT
    $verStr = if ($result.Verdict) { [string]$result.Verdict } else { "UNKNOWN" }
    Out-Str $pos.Ver $row (Format-CellCenter $verStr 18) $result.Color
}

function Write-ResultLatency($row, $result, [int]$TargetIndex = -1) {
    if ($TargetIndex -ge 0) {
        $row = Get-TableScreenRow -TargetIndex $TargetIndex
    }
    if ($row -lt 0 -or $row -ge [Console]::BufferHeight) { return }
    try {
        $nav = Get-ControlsRow -count $(if ($script:Targets) { $script:Targets.Count } else { 0 })
        if ($row -ge $nav) { return }
    } catch { }

    if ($script:UiCursorHidden -ne $true) {
        [Console]::CursorVisible = $false
        $script:UiCursorHidden = $true
    }
    $pos = if ($script:DynamicColPos) { $script:DynamicColPos } else { $CONST.UI }
    $latStr = if ($result.Lat) { [string]$result.Lat } else { "---" }
    $latCol = if($latStr -eq "---") {"DarkGray"} else {"Cyan"}
    $latW = 12
    try {
        if ($script:DynamicColPos -and $script:DynamicColPos.Ver -gt $script:DynamicColPos.Lat) {
            $latW = [Math]::Max(12, $script:DynamicColPos.Ver - $script:DynamicColPos.Lat - 2)
        }
    } catch { }
    Out-Str $pos.Lat $row (Format-LatCell -LatText $latStr -TotalWidth $latW -NumWidth 4 -BarWidth 6) $latCol
}


function Check-UpdateVersion {
    param(
        [string]$Repo = "Shiperoid/YT-DPI",
        [string]$LastCheckedVersion = "",
        [switch]$IgnoreLastChecked = $false,
        [switch]$ManualMode = $false # Флаг ручного нажатия 'U'
    )
    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        Write-DebugLog "Проверка обновлений (API)..."
        $request = [System.Net.WebRequest]::Create($apiUrl)
        $request.UserAgent = $script:UserAgent
        $request.Timeout = 5000
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $json = $reader.ReadToEnd()
        $release = $json | ConvertFrom-Json
        $latestVersion = $release.tag_name -replace '^v', ''

        $vLatest = Normalize-Version $latestVersion
        $vCurrent = Normalize-Version $scriptVersion

        Write-DebugLog "GitHub: $latestVersion ($vLatest) | Локально: $scriptVersion ($vCurrent)"

        # Если мы нажали кнопку 'U', нам важно знать результат, даже если обнов нет
        if ($ManualMode) {
            if ($vLatest -gt $vCurrent) { return $latestVersion } # Есть новее
            if ($vLatest -eq $vCurrent) { return "LATEST" }      # Уже последняя
            return "DEV_VERSION"                                 # У нас новее (бета/дев)
        }

        # Автоматическая проверка (тихая)
        if (-not $IgnoreLastChecked -and $latestVersion -eq $LastCheckedVersion) { return $null }
        if ($vLatest -gt $vCurrent) { return $latestVersion }

    } catch {
        Write-DebugLog "Ошибка API GitHub: $_" "WARN"
    }
    return $null
}

function Stop-Script {
    Write-DebugLog "Инициировано завершение работы..."
    [Console]::CursorVisible = $true
    [Console]::ResetColor()

    # 1. Сначала сохраняем
    Save-Config $script:Config

    # 2. Небольшая пауза, чтобы файловая система успела "переварить" запись
    Start-Sleep -Milliseconds 200

    Write-DebugLog "--- СЕССИЯ ЗАВЕРШЕНА ---" "INFO"

    try { Stop-DeferredPostScanExtras } catch { }
    try { Close-ScanRunspacePool } catch { }

    # 3. Убиваем процесс
    [System.Diagnostics.Process]::GetCurrentProcess().Kill()
}

# ====================================================================================
# UPDATER АПДЕЙТЕР ОБНОВЛЕНИЕ СКРИПТА ЧЕРЕЗ GITHUB
# ====================================================================================
function Invoke-Update {
    param($Config)
    Draw-StatusBar -Message "[ UPDATE ] Проверка обновлений на GitHub..." -Fg "Black" -Bg "Cyan"

    $res = Check-UpdateVersion -ManualMode -IgnoreLastChecked

    if ($res -eq "LATEST") {
        Draw-StatusBar -Message "[ UPDATE ] Вы уже используете последнюю версию ($scriptVersion)" -Fg "Black" -Bg "DarkGreen"
        # Обновляем LastCheckedVersion
        $Config.LastCheckedVersion = $scriptVersion
        Save-Config $Config
        Start-Sleep -Seconds 2
    }
    elseif ($res -eq "DEV_VERSION") {
        Draw-StatusBar -Message "[ UPDATE ] Ваша верися ($scriptVersion) новее, чем GitHub релиз ($res)." -Fg "Black" -Bg "Magenta"
        # Обновляем LastCheckedVersion, чтобы не показывать снова
        $Config.LastCheckedVersion = $scriptVersion
        Save-Config $Config
        Start-Sleep -Seconds 3
    }
    elseif ($null -ne $res) {
        Draw-StatusBar -Message "[ UPDATE ] Новая версия $res доступна! Установить сейчас? (Y/N)" -Fg "Black" -Bg "Yellow"
        $menuKey = Read-MenuKeyOrResize
        if ($menuKey.Resized) { continue }
        $key = $menuKey.KeyChar
        if ($key -eq 'y' -or $key -eq 'Y' -or $key -eq 'н' -or $key -eq 'Н') { #Добавил обработку кириллицы
            $currentFile = $script:OriginalFilePath
            $downloadUrl = if ($currentFile -match '\.(?i)bat$') {
                "https://raw.githubusercontent.com/Shiperoid/YT-DPI/master/YT-DPI.bat"
            } else {
                "https://raw.githubusercontent.com/Shiperoid/YT-DPI/master/YT-DPI.ps1"
            }
            Start-Updater $currentFile $downloadUrl
            exit
        } else {
            # Если отказались, запоминаем, что предложили эту версию
            $Config.LastCheckedVersion = $res
            Save-Config $Config
        }
    } else {
        Draw-StatusBar -Message "[ UPDATE ] Сервер обновлений недоступен или достигнул лимит API." -Fg "Black" -Bg "Red"
        Start-Sleep -Seconds 2
    }
}

# --- Вспомогательные функции ---
# ====================================================================================
# ФУНКЦИЯ ПОДКЛЮЧЕНИЯ ЧЕРЕЗ ПРОКСИ
# ====================================================================================
function Connect-ThroughProxy {
        param(
            $TargetHost,
            $TargetPort,
            $ProxyConfig,
            [int]$Timeout = $CONST.ProxyTimeout
        )
        Write-DebugLog "Connect-ThroughProxy: $($ProxyConfig.Type) $($ProxyConfig.Host):$($ProxyConfig.Port) -> $($TargetHost):$($TargetPort)"

        $maxAttempts = 3
        $delayMs = 500
        $lastError = $null

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $tcp = $null
            $stream = $null
            try {
                Write-DebugLog "Попытка $attempt подключения к $($ProxyConfig.Host):$($ProxyConfig.Port)"
                $tcp = New-Object System.Net.Sockets.TcpClient
                $asyn = $tcp.BeginConnect($ProxyConfig.Host, $ProxyConfig.Port, $null, $null)
                if (-not $asyn.AsyncWaitHandle.WaitOne($Timeout)) {
                    throw "Proxy connection timeout"
                }
                $tcp.EndConnect($asyn)
                $stream = $tcp.GetStream()
                $stream.ReadTimeout = $Timeout
                $stream.WriteTimeout = $Timeout

                if ($ProxyConfig.Type -eq "SOCKS5") {
                    Write-DebugLog "SOCKS5: начало рукопожатия"

                    # === Определяем, какие методы аутентификации предложить ===
                    $methods = @()
                    if ($ProxyConfig.User -and $ProxyConfig.Pass) {
                        # Если есть логин/пароль, предлагаем сначала аутентификацию по паролю (0x02), затем без аутентификации (0x00)
                        $methods = @(0x02, 0x00)
                    } else {
                        # Без аутентификации предлагаем только 0x00
                        $methods = @(0x00)
                    }
                    $greeting = [byte[]](@(0x05, $methods.Count) + $methods)
                    $stream.Write($greeting, 0, $greeting.Length)

                    # Читаем ответ сервера (2 байта: VER, METHOD)
                    $resp = New-Object byte[] 2
                    if ($stream.Read($resp, 0, 2) -ne 2) {
                        throw "SOCKS5: нет ответа на выбор метода"
                    }
                    if ($resp[0] -ne 0x05) {
                        throw "SOCKS5: неверная версия ответа (ожидалась 0x05, получена 0x$('{0:X2}' -f $resp[0]))"
                    }

                    $method = $resp[1]
                    Write-DebugLog "SOCKS5: сервер выбрал метод аутентификации 0x$('{0:X2}' -f $method)"

                    # === Обработка выбранного метода ===
                    if ($method -eq 0x00) {
                        # Без аутентификации — ничего не делаем
                        Write-DebugLog "SOCKS5: аутентификация не требуется"
                    }
                    elseif ($method -eq 0x02) {
                        # Аутентификация по логину/паролю
                        if (-not $ProxyConfig.User -or -not $ProxyConfig.Pass) {
                            throw "SOCKS5: сервер требует логин/пароль, но они не указаны в настройках"
                        }
                        $u = [Text.Encoding]::UTF8.GetBytes($ProxyConfig.User)
                        $p = [Text.Encoding]::UTF8.GetBytes($ProxyConfig.Pass)
                        $authMsg = [byte[]](@(0x01, $u.Length) + $u + @($p.Length) + $p)
                        $stream.Write($authMsg, 0, $authMsg.Length)

                        $authResp = New-Object byte[] 2
                        if ($stream.Read($authResp, 0, 2) -ne 2) {
                            throw "SOCKS5: нет ответа на аутентификацию"
                        }
                        if ($authResp[0] -ne 0x01 -or $authResp[1] -ne 0x00) {
                            throw "SOCKS5: неверный логин/пароль (код $($authResp[1]))"
                        }
                        Write-DebugLog "SOCKS5: аутентификация успешна"
                    }
                    elseif ($method -eq 0xFF) {
                        throw "SOCKS5: сервер отверг все предложенные методы аутентификации (0xFF). Проверьте, требуется ли аутентификация."
                    }
                    else {
                        throw "SOCKS5: сервер выбрал неподдерживаемый метод аутентификации 0x$('{0:X2}' -f $method)"
                    }

                    # === Запрос на подключение к целевому хосту ===
                    $addrType = 0x03   # domain name
                    $hostBytes = [Text.Encoding]::UTF8.GetBytes($TargetHost)
                    $req = [byte[]](@(0x05, 0x01, 0x00, $addrType, $hostBytes.Length) + $hostBytes + @([math]::Floor($TargetPort/256), ($TargetPort%256)))
                    $stream.Write($req, 0, $req.Length)

                    # Читаем ответ (минимум 10 байт)
                    $resp = New-Object byte[] 10
                    $read = 0
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($read -lt 10 -and $sw.ElapsedMilliseconds -lt $Timeout) {
                        if ($stream.DataAvailable) {
                            $r = $stream.Read($resp, $read, 10 - $read)
                            if ($r -eq 0) { break }
                            $read += $r
                        } else { Start-Sleep -Milliseconds 20 }
                    }
                    if ($read -lt 10) { throw "SOCKS5: неполный ответ на запрос подключения" }
                    if ($resp[0] -ne 0x05) { throw "SOCKS5: неверная версия в ответе на подключение" }
                    if ($resp[1] -ne 0x00) {
                        $repCode = $resp[1]
                        $errorMap = @{
                            0x01 = "general failure"
                            0x02 = "connection not allowed"
                            0x03 = "network unreachable"
                            0x04 = "host unreachable"
                            0x05 = "connection refused"
                            0x06 = "TTL expired"
                            0x07 = "command not supported"
                            0x08 = "address type not supported"
                        }
                        $errText = if ($errorMap.ContainsKey($repCode)) { $errorMap[$repCode] } else { "unknown error 0x$('{0:X2}' -f $repCode)" }
                        throw "SOCKS5: сервер вернул ошибку - $errText"
                    }
                    Write-DebugLog "SOCKS5: маршрут установлен успешно"
                    return @{ Tcp = $tcp; Stream = $stream }
                }
                elseif ($ProxyConfig.Type -eq "HTTP") {
                    $hdr = "CONNECT ${TargetHost}:$TargetPort HTTP/1.1`r`nHost: ${TargetHost}:$TargetPort`r`n"
                    if ($ProxyConfig.User -and $ProxyConfig.Pass) {
                        $authBytes = [Text.Encoding]::ASCII.GetBytes("$($ProxyConfig.User):$($ProxyConfig.Pass)")
                        $hdr += "Proxy-Authorization: Basic $([Convert]::ToBase64String($authBytes))`r`n"
                    }
                    $hdr += "`r`n"
                    $reqBytes = [Text.Encoding]::ASCII.GetBytes($hdr)
                    $stream.Write($reqBytes, 0, $reqBytes.Length)
                    $swRead = [System.Diagnostics.Stopwatch]::StartNew()
                    $response = ""
                    $buf = New-Object byte[] 1024
                    while ($swRead.ElapsedMilliseconds -lt $Timeout) {
                        if ($stream.DataAvailable) {
                            $r = $stream.Read($buf, 0, 1024)
                            if ($r -le 0) { break }
                            $response += [Text.Encoding]::ASCII.GetString($buf, 0, $r)
                            if ($response -match "`r`n`r`n") { break }
                        } else { Start-Sleep -Milliseconds 20 }
                    }
                    if ($response -match '(?m)HTTP/1\.\d\s+200') {
                        Write-DebugLog "HTTP CONNECT tunnel OK -> ${TargetHost}:$TargetPort"
                        return @{ Tcp = $tcp; Stream = $stream }
                    }
                    $snip = if ($response.Length -gt 160) { $response.Substring(0, 160) + "..." } else { $response }
                    throw "HTTP CONNECT не 200: $snip"
                }
                else {
                    throw "Неподдерживаемый тип прокси для туннеля: $($ProxyConfig.Type)"
                }
            } catch {
                $lastError = $_
                Write-DebugLog "Ошибка подключения к прокси (попытка $attempt): $lastError"
                if ($tcp) { try { $tcp.Close() } catch {} }
                if ($attempt -eq $maxAttempts) { throw $lastError }
                $sleep = $delayMs * [math]::Pow(2, $attempt - 1)
                Start-Sleep -Milliseconds $sleep
            }
        }
    }

    # Вспомогательная функция для чтения фиксированного количества байт с таймаутом
    function Read-StreamWithTimeout($stream, $buffer, $count, $timeout) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $totalRead = 0
        while ($totalRead -lt $count) {
            if ($sw.ElapsedMilliseconds -ge $timeout) { return $totalRead }
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, $totalRead, $count - $totalRead)
                if ($read -eq 0) { return $totalRead }
                $totalRead += $read
            } else {
                Start-Sleep -Milliseconds 50
            }
        }
        return $totalRead
    }

    # Вспомогательная функция для чтения HTTP-ответа до \r\n\r\n
    function Read-HttpResponse($stream, $timeout) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = ""
        $buffer = New-Object byte[] 1024
        while ($sw.ElapsedMilliseconds -lt $timeout) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, 0, 1024)
                if ($read -gt 0) {
                    $response += [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                    if ($response -match "\r\n\r\n") { break }
                } else { break }
            } else {
                Start-Sleep -Milliseconds 50
            }
        }
        return $response
    }

# ====================================================================================
# СЕТЕВЫЕ ФУНКЦИИ
# ====================================================================================
function Invoke-WebRequestViaProxy($Url, $Method = "GET", $Timeout = $CONST.TimeoutMs) {
    Write-DebugLog "Invoke-WebRequestViaProxy: $Method $Url"
    $uri = [System.Uri]$Url

    # Режим прямого подключения или HTTP-прокси
    if (-not $global:ProxyConfig.Enabled -or $global:ProxyConfig.Type -eq "HTTP") {
        try {
            $req = [System.Net.WebRequest]::Create($uri)
            $req.Timeout = $Timeout
            $req.UserAgent = $script:UserAgent
            if ($global:ProxyConfig.Enabled) {
                $wp = New-Object System.Net.WebProxy($global:ProxyConfig.Host, $global:ProxyConfig.Port)
                if ($global:ProxyConfig.User) { $wp.Credentials = New-Object System.Net.NetworkCredential($global:ProxyConfig.User, $global:ProxyConfig.Pass) }
                $req.Proxy = $wp
            } else { $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy() }

            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $content = $reader.ReadToEnd()
            $resp.Close()
            return $content
        } catch { return "" }
    }
    # Режим SOCKS5 (Исправлено для HTTPS)
    else {
        try {
            $conn = Connect-ThroughProxy $uri.Host $uri.Port $global:ProxyConfig $Timeout
            $stream = $conn.Stream

            # --- КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: SSL-обертка для SOCKS ---
            if ($uri.Scheme -eq "https") {
                if ($script:AllowInsecureTls) {
                    $sslStream = New-Object System.Net.Security.SslStream($stream, $false, { $true })
                } else {
                    $sslStream = New-Object System.Net.Security.SslStream($stream, $false)
                }
                $sslStream.AuthenticateAsClient($uri.Host)
                $stream = $sslStream
            }

            $request = "$Method $($uri.PathAndQuery) HTTP/1.1`r`nHost: $($uri.Host)`r`nUser-Agent: $script:UserAgent`r`nConnection: close`r`n`r`n"
            $reqBytes = [Text.Encoding]::ASCII.GetBytes($request)
            $stream.Write($reqBytes, 0, $reqBytes.Length)

            $buf = New-Object byte[] 8192
            $respBytes = New-Object System.Collections.Generic.List[byte]
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            while ($sw.ElapsedMilliseconds -lt $Timeout) {
                if ($conn.Tcp.Available -gt 0 -or ($uri.Scheme -eq "https" -and $true)) {
                    try {
                        $read = $stream.Read($buf, 0, 8192)
                        if ($read -gt 0) {
                            for ($i=0; $i -lt $read; $i++) { $respBytes.Add($buf[$i]) }
                        } else { break }
                    } catch { break }
                } else { Start-Sleep -Milliseconds 50 }
            }

            $fullResponse = [Text.Encoding]::UTF8.GetString($respBytes.ToArray())
            $conn.Tcp.Close()

            # Извлекаем только тело ответа (после \r\n\r\n)
            if ($fullResponse -match '(?s)\r\n\r\n(.*)') {
                return $matches[1]
            }
            return $fullResponse
        } catch {
            Write-DebugLog "SOCKS WebRequest Error: $($_.Exception.Message)"
            return ""
        }
    }
}

# ===== ГЕО-КЭШ С ПРОДЛЕННЫМ TTL =====
$script:GeoCacheFile = Join-Path $script:ConfigDir "geo_cache.json"
$script:LastGeoUpdate = $null

function Get-GeoProxyKey {
    if (-not $global:ProxyConfig.Enabled) { return "direct" }
    $t = $global:ProxyConfig.Type
    $h = $global:ProxyConfig.Host
    $p = $global:ProxyConfig.Port
    return "${t}|${h}:${p}"
}

function Get-CachedGeoInfo {
    param([int]$MaxAgeHours = 24)

    $wantProxyKey = Get-GeoProxyKey
    if (Test-Path $script:GeoCacheFile) {
        try {
            $cached = Get-Content $script:GeoCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $cacheAge = (Get-Date).Ticks - $cached.TimestampTicks
            $ageHours = [TimeSpan]::FromTicks($cacheAge).TotalHours
            $cachedKey = if ($cached.ProxyKey) { [string]$cached.ProxyKey } else { "" }
            if ($cachedKey -ne $wantProxyKey) {
                Write-DebugLog "GEO кэш отброшен: другой прокси/VPN контекст (кэш='$cachedKey', сейчас='$wantProxyKey')" "INFO"
                return $null
            }

            if ($ageHours -lt $MaxAgeHours) {
                Write-DebugLog "Используем GEO кэш (возраст: $([math]::Round($ageHours,1)) часов)" "INFO"
                return @{
                    ISP = $cached.ISP
                    LOC = $cached.LOC
                    IsCached = $true
                    AgeHours = $ageHours
                }
            } else {
                Write-DebugLog "GEO кэш устарел (возраст: $([math]::Round($ageHours,1)) часов)" "INFO"
            }
        } catch {
            Write-DebugLog "Ошибка чтения GEO кэша: $_" "WARN"
        }
    }
    return $null
}

function Save-GeoCache {
    param($isp, $loc)

    $cacheData = @{
        ISP = $isp
        LOC = $loc
        ProxyKey = (Get-GeoProxyKey)
        TimestampTicks = (Get-Date).Ticks
        ScriptVersion = $scriptVersion
    }

    try {
        $cacheData | ConvertTo-Json | Set-Content $script:GeoCacheFile -Encoding UTF8 -Force
        Write-DebugLog "GEO кэш сохранен: $isp / $loc" "INFO"
    } catch {
        Write-DebugLog "Ошибка сохранения GEO кэша: $_" "WARN"
    }
}

function Get-NetworkInfo {
    Write-DebugLog "Get-NetworkInfo: начало"

    # 1. БЫСТРЫЙ DNS
    $dns = Get-SystemDnsPrimary

    # 2. CDN через redirector (через тот же путь, что и остальной HTTP: $global:ProxyConfig)
    $cdn = "manifest.googlevideo.com"
    try {
        $rnd = [guid]::NewGuid().ToString().Substring(0, 8)
        $redirectorUrl = "http://redirector.googlevideo.com/report_mapping?di=no&nocache=$rnd"
        $rawCdn = Invoke-WebRequestViaProxy $redirectorUrl "GET" 3000
        if ($rawCdn) {
            $cdnShort = $null
            if ($rawCdn -match '=>\s+([\w-]+)') { $cdnShort = $matches[1] }
            if ($cdnShort -and $cdnShort -ne 'r1') {
                $cdn = "r1.$cdnShort.googlevideo.com"
            }
            elseif ($rawCdn -match '=>\s*([a-zA-Z0-9.\-]+\.googlevideo\.com)') {
                $cdn = $matches[1]
            }
        }
    } catch { Write-DebugLog "CDN redirector: $_" "WARN" }

    # 3. ГЕО-ИНФОРМАЦИЯ (синхронно; запросы идут через Invoke-WebRequestViaProxy = учёт HTTP/SOCKS5 прокси)
    $isp = "Detecting..."
    $loc = "Please wait"

    $cachedGeo = Get-CachedGeoInfo -MaxAgeHours 24
    if ($cachedGeo) {
        $isp = $cachedGeo.ISP
        $loc = $cachedGeo.LOC
        Write-DebugLog "GEO из кэша: $isp / $loc"
    }
    else {
        $providers = @(Get-GeoProviderDefinitions)
        $geoTimeout = 2000
        if ($CONST.NetInfo -and $null -ne $CONST.NetInfo.GeoPerRequestMs) {
            $geoTimeout = [Math]::Max(1500, [int]$CONST.NetInfo.GeoPerRequestMs)
        }

        $geoResult = $null
        foreach ($provider in $providers) {
            try {
                Write-DebugLog "GEO: пробуем $($provider.Name)"
                $raw = Invoke-WebRequestViaProxy $provider.Url "GET" $geoTimeout
                if ($raw -match '\{.*\}') {
                    $json = $raw | ConvertFrom-Json
                    if (& $provider.Check $json) {
                        $ispRaw = & $provider.GetISP $json
                        $locRaw = & $provider.GetLOC $json
                        if ($ispRaw -and $locRaw) {
                            $geoResult = [PSCustomObject]@{
                                ISP = $ispRaw -replace '(?i)\s*(LLC|Inc\.?|Ltd\.?|sp\. z o\.o\.|CJSC|OJSC|PJSC|PAO|ZAO|OOO|JSC|Private Enterprise|Group|Corporation|Ltd|Limited)', ''
                                LOC = $locRaw
                            }
                            Write-DebugLog "GEO успех ($($provider.Name)): $($geoResult.ISP) / $($geoResult.LOC)"
                            break
                        }
                    }
                }
            }
            catch {
                Write-DebugLog "GEO $($provider.Name) ошибка: $_"
            }
        }

        if ($geoResult) {
            $isp = $geoResult.ISP
            $loc = $geoResult.LOC
            Save-GeoCache -isp $isp -loc $loc
        }
        else {
            Write-DebugLog "Все GEO-провайдеры недоступны"
            $isp = "Geo unavailable"
            $loc = "Use --fast-mode"
        }
    }

    if ($isp.Length -gt 30) { $isp = $isp.Substring(0, 27) + "..." }

    # 4. IPv6 тест
    $hasV6 = $false
    if ($script:Config.IpPreference -ne "IPv4") {
        try {
            $t = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6)
            $a = $t.BeginConnect("ipv6.google.com", 80, $null, $null)
            if ($a.AsyncWaitHandle.WaitOne(1000)) {
                $t.EndConnect($a)
                $hasV6 = $true
            }
            $t.Close()
        } catch { }
    }

    $result = @{
        DNS = $dns
        CDN = $cdn
        ISP = $isp
        LOC = $loc
        TimestampTicks = (Get-Date).Ticks
        HasIPv6 = $hasV6
    }

    return $result
}

function Show-SettingsMenu {
    while ($true) {
        [Console]::Clear()
        $w = [Console]::WindowWidth
        if ($w -gt 80) { $w = 80 }
        $line = "═" * $w

        Write-Host "`n $line" -ForegroundColor Cyan
        Write-Host (Get-PaddedCenter "SETTINGS / НАСТРОЙКИ" $w) -ForegroundColor Yellow
        Write-Host " $line" -ForegroundColor Cyan

        # Безопасное получение текущей настройки
        $curPref = "IPv6"
        if ($script:Config -and $script:Config.IpPreference) {
            $curPref = $script:Config.IpPreference
        }

        $curTls = "Auto"
        if ($script:Config -and $script:Config.TlsMode) {
            $curTls = [string]$script:Config.TlsMode
        }
        if ([string]::IsNullOrWhiteSpace($curTls)) { $curTls = "Auto" }

        Write-Host "`n  1. Протокол IP : " -NoNewline -ForegroundColor White
        if ($curPref -eq "IPv6") {
            Write-Host "[ IPv6 ПРИОРИТЕТ ]" -ForegroundColor Green
            Write-Host "     (Используется IPv6, если доступен. Откат на IPv4 при ошибках)" -ForegroundColor Gray
        } else {
            Write-Host "[ ТОЛЬКО IPv4 ]" -ForegroundColor Yellow
            Write-Host "     (IPv6 полностью игнорируется)" -ForegroundColor Gray
        }

        Write-Host "`n  2. Сброс сетевого кэша" -ForegroundColor White
        Write-Host "     (Очистка DNS-записей и данных о провайдере)" -ForegroundColor Gray

        Write-Host "`n  3. Режим TLS при сканировании " -NoNewline -ForegroundColor White
        Write-Host "[ $curTls ]" -ForegroundColor Cyan
        Write-Host "     Auto — колонки T12 и T13 (как по умолчанию)." -ForegroundColor Gray
        Write-Host "     TLS12 — в таблице осмысленен столбец T12 (T13 остаётся N/A); при DRP/RST тихо проверяется T13 только для вердикта." -ForegroundColor Gray
        Write-Host "     TLS13 — наоборот: столбец T13 основной (T12 N/A); при DRP/RST тихо проверяется T12 для вердикта." -ForegroundColor Gray
        Write-Host "     Нажмите 3, чтобы переключить: Auto → TLS12 → TLS13 → Auto" -ForegroundColor DarkGray

        $curParallelTls = $false
        if ($script:Config -and ($script:Config.ScanParallelTlsFirstPass -eq $true)) { $curParallelTls = $true }

        $curDbgLog = $false
        if ($script:Config -and ($script:Config.DebugLogEnabled -eq $true)) { $curDbgLog = $true }
        Write-Host "`n  4. Запись отладки в файл " -NoNewline -ForegroundColor White
        if ($curDbgLog) {
            Write-Host "[ ВКЛ ]" -ForegroundColor Green
        } else {
            Write-Host "[ ВЫКЛ ]" -ForegroundColor DarkGray
        }
        Write-Host "     Файл: YT-DPI_Debug.log (рядом со скриптом). Дополнительно: переменная YT_DPI_DEBUG." -ForegroundColor Gray
        Write-Host "     Включено, если ВКЛ в меню или задана YT_DPI_DEBUG=1." -ForegroundColor DarkGray

        $curFullId = $false
        if ($script:Config -and ($script:Config.DebugLogFullIdentifiers -eq $true)) { $curFullId = $true }
        Write-Host "`n  5. Полные идентификаторы в заголовке лога " -NoNewline -ForegroundColor White
        if ($curFullId) {
            Write-Host "[ ВКЛ — ПК, пользователь, пути ]" -ForegroundColor Yellow
        } else {
            Write-Host "[ ВЫКЛ — обезличено ]" -ForegroundColor Green
        }
        Write-Host "     Для разового полного заголовка: YT_DPI_DEBUG_IDENTIFIERS=1 (перекрывает ВЫКЛ в конфиге)." -ForegroundColor Gray

        $curUseCustom = ($script:Config.UseCustomTargets -eq $true)
        Write-Host "`n  6. Использовать кастомный файл целей (targets.txt) " -NoNewline -ForegroundColor White
        if ($curUseCustom) { Write-Host "[ ВКЛ ]" -ForegroundColor Green } else { Write-Host "[ ВЫКЛ ]" -ForegroundColor DarkGray }
        Write-Host "     Если ВКЛ и файл targets.txt существует и не пуст — используется он." -ForegroundColor Gray
        Write-Host "     Если ВЫКЛ — всегда используется встроенный список Youtube/Google." -ForegroundColor Gray

        Write-Host "`n  7. Экспортировать текущие цели в targets.txt " -ForegroundColor White
        Write-Host "     (перезапишет файл, создаст при отсутствии; после экспорта ВКЛ автоматически)" -ForegroundColor Gray

        $curLatBars = $true
        if ($script:Config -and ($null -ne $script:Config.UiShowLatBars)) { $curLatBars = [bool]$script:Config.UiShowLatBars }
        Write-Host "`n  9. LAT bars в таблице " -NoNewline -ForegroundColor White
        if ($curLatBars) { Write-Host "[ ВКЛ ]" -ForegroundColor Green } else { Write-Host "[ ВЫКЛ ]" -ForegroundColor DarkGray }

        $curCharset = "Blocks"
        if ($script:Config -and $script:Config.GraphCharset) { $curCharset = [string]$script:Config.GraphCharset }
        Write-Host "`n  A. Graph charset " -NoNewline -ForegroundColor White
        Write-Host "[ $curCharset ]" -ForegroundColor Cyan
        Write-Host "     Blocks (Unicode) или Ascii (#*=) для старых консолей/скриншотов." -ForegroundColor Gray

        $curGw = 10
        if ($script:Config -and $script:Config.GraphWidth) { $curGw = [int]$script:Config.GraphWidth }
        $curPh = 15
        if ($script:Config -and $script:Config.PathMaxHops) { $curPh = [int]$script:Config.PathMaxHops }
        $curPs = 3
        if ($script:Config -and $script:Config.PathSamples) { $curPs = [int]$script:Config.PathSamples }
        Write-Host "`n  B. PATH: GraphWidth=$curGw  MaxHops=$curPh  Samples=$curPs (cycle B)" -ForegroundColor White
        Write-Host "     Клавиша G на главном экране — ICMP mtr-lite к домену." -ForegroundColor Gray

        Write-Host "`n  0. Назад в главное меню" -ForegroundColor DarkGray
        Write-Host "`n $line" -ForegroundColor Cyan
        Write-Host " ВЫБЕРИТЕ ПУНКТ (1–9, A–B, 0): " -NoNewline -ForegroundColor Yellow

        Update-UiConsoleSnapshot
        $menuKey = Read-MenuKeyOrResize
        if ($menuKey.Resized) { continue }
        $key = $menuKey.KeyChar

        try {
            if ($key -eq "1") {
                $newVal = if ($curPref -eq "IPv6") { "IPv4" } else { "IPv6" }

                # Вместо прямого присвоения используем Add-Member с ключом -Force
                # Это сработает, даже если поля не было
                $script:Config | Add-Member -MemberType NoteProperty -Name "IpPreference" -Value $newVal -Force

                $script:DnsCache = [hashtable]::Synchronized(@{})
                Save-Config $script:Config
            }
            elseif ($key -eq "2") {
                # Безопасная очистка
                $script:DnsCache = [hashtable]::Synchronized(@{})

                if ($script:Config.NetCache) {
                    $script:Config.NetCache.ISP = "Loading..."
                }
                if (Test-Path $script:GeoCacheFile) {
                    try { Remove-Item $script:GeoCacheFile -Force -ErrorAction SilentlyContinue } catch {}
                }

                Save-Config $script:Config
                Write-Host "`n  [OK] Кэш очищен!" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            elseif ($key -eq "3") {
                $tm = if ($script:Config.TlsMode) { [string]$script:Config.TlsMode } else { "Auto" }
                if ([string]::IsNullOrWhiteSpace($tm)) { $tm = "Auto" }
                $nextTls = "Auto"
                if ($tm -match '^(?i)Auto$') {
                    $nextTls = "TLS12"
                }
                elseif ($tm -match '^(?i)TLS12$') {
                    $nextTls = "TLS13"
                }
                else {
                    $nextTls = "Auto"
                }
                $script:Config | Add-Member -MemberType NoteProperty -Name "TlsMode" -Value $nextTls -Force
                Save-Config $script:Config
                Write-Host "`n  [OK] Режим TLS: $nextTls (сохранено в конфиг)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            elseif ($key -eq "4") {
                $nextDbg = -not $curDbgLog
                $script:Config | Add-Member -MemberType NoteProperty -Name "DebugLogEnabled" -Value $nextDbg -Force
                Save-Config $script:Config
                if ($nextDbg) {
                    $script:DebugSessionHeaderWritten = $false
                    Write-DebugLogSessionHeaderIfNeeded
                }
                $st = if ($nextDbg) { "ВКЛ" } else { "ВЫКЛ" }
                Write-Host "`n  [OK] Отладочный лог в файл: $st (сохранено в конфиг)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            elseif ($key -eq "5") {
                $nextFull = -not $curFullId
                $script:Config | Add-Member -MemberType NoteProperty -Name "DebugLogFullIdentifiers" -Value $nextFull -Force
                Save-Config $script:Config
                if (Test-DebugLogEnabled) {
                    $script:DebugSessionHeaderWritten = $false
                    Write-DebugLogSessionHeaderIfNeeded
                }
                $st5 = if ($nextFull) { "ВКЛ (осторожно при отправке лога в чат)" } else { "ВЫКЛ (обезличивание)" }
                Write-Host "`n  [OK] Полные идентификаторы в логе: $st5" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            elseif ($key -eq "6") {
                Write-DebugLog "=== Меню: пункт 6 (переключение UseCustomTargets) ===" "DEBUG"
                $oldUse = $curUseCustom
                $newUse = -not $oldUse
                Write-DebugLog "Текущее UseCustomTargets: $oldUse, новое значение: $newUse" "DEBUG"

                $script:Config | Add-Member -MemberType NoteProperty -Name "UseCustomTargets" -Value $newUse -Force
                Save-Config $script:Config
                Write-DebugLog "Настройка сохранена в конфиг." "DEBUG"

                Write-DebugLog "Вызов Initialize-Targets для перезагрузки списка целей..." "DEBUG"
                Initialize-Targets
                Write-DebugLog "Initialize-Targets завершён." "DEBUG"

                $st6 = if ($newUse) { "ВКЛ" } else { "ВЫКЛ" }
                Write-Host "`n  [OK] Использование кастомного файла целей: $st6" -ForegroundColor Green
                Write-DebugLog "Пользователь включил/выключил кастомный файл: $st6" "INFO"
                Start-Sleep -Seconds 1
            }
            elseif ($key -eq "7") {
                Write-DebugLog "=== Меню: пункт 7 (экспорт целей в targets.txt) ===" "DEBUG"

                $parentDir = Split-Path -Parent $script:OriginalFilePath
                $targetsFile = Join-Path $parentDir "targets.txt"
                Write-DebugLog "Путь для экспорта: $targetsFile" "DEBUG"
                Write-DebugLog "Родительская директория (ParentDir): $parentDir" "DEBUG"

                $exportList = $script:BaseTargets
                Write-DebugLog "Текущий список целей (BaseTargets) содержит $($exportList.Count) элементов." "DEBUG"
                if ($exportList.Count -eq 0) {
                    Write-DebugLog "ОШИБКА: нечего экспортировать — список целей пуст." "ERROR"
                    Write-Host "`n  [ОШИБКА] Нет целей для экспорта!" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }

                try {
                    Write-DebugLog "Попытка записи $($exportList.Count) строк в файл $targetsFile (UTF-8 без BOM)..." "INFO"
                    [System.IO.File]::WriteAllLines($targetsFile, $exportList, [System.Text.UTF8Encoding]::new($false))
                    Write-DebugLog "Файл успешно записан." "DEBUG"

                    # Проверяем, что файл действительно создан
                    if (Test-Path $targetsFile) {
                        Write-DebugLog "Файл подтверждён: $(Get-Item $targetsFile | Select-Object Length, LastWriteTime)" "DEBUG"
                    } else {
                        Write-DebugLog "Предупреждение: файл не обнаружен после записи!" "WARN"
                    }

                    Write-Host "`n  [OK] Экспортировано $($exportList.Count) целей в файл:`n       $targetsFile" -ForegroundColor Green

                    # Принудительно включаем использование кастомного файла
                    Write-DebugLog "Принудительная установка UseCustomTargets = true" "DEBUG"
                    $script:Config | Add-Member -MemberType NoteProperty -Name "UseCustomTargets" -Value $true -Force
                    Save-Config $script:Config
                    Write-DebugLog "Настройка сохранена." "DEBUG"

                    Write-DebugLog "Вызов Initialize-Targets для перезагрузки из свежесозданного файла..." "DEBUG"
                    Initialize-Targets
                    Write-DebugLog "Initialize-Targets завершён." "DEBUG"
                } catch {
                    Write-DebugLog "ОШИБКА при записи файла: $($_.Exception.Message)" "ERROR"
                    Write-DebugLog "Стек вызова: $($_.ScriptStackTrace)" "DEBUG"
                    Write-Host "`n  [ОШИБКА] Не удалось записать файл: $($_.Exception.Message)" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                }
            }
            elseif ($key -eq "9") {
                $next = -not $curLatBars
                $script:Config | Add-Member -MemberType NoteProperty -Name "UiShowLatBars" -Value $next -Force
                Save-Config $script:Config
            }
            elseif ($key -eq "a" -or $key -eq "A") {
                $next = if ($curCharset -eq "Blocks") { "Ascii" } else { "Blocks" }
                $script:Config | Add-Member -MemberType NoteProperty -Name "GraphCharset" -Value $next -Force
                Save-Config $script:Config
            }
            elseif ($key -eq "b" -or $key -eq "B") {
                $gw = $curGw; if ($gw -lt 8) { $gw = 8 } elseif ($gw -lt 12) { $gw = 12 } elseif ($gw -lt 16) { $gw = 16 } else { $gw = 8 }
                $ph = $curPh; if ($ph -lt 10) { $ph = 10 } elseif ($ph -lt 15) { $ph = 15 } elseif ($ph -lt 20) { $ph = 20 } else { $ph = 10 }
                $ps = $curPs; if ($ps -lt 3) { $ps = 3 } elseif ($ps -lt 5) { $ps = 5 } else { $ps = 1 }
                $script:Config | Add-Member -MemberType NoteProperty -Name "GraphWidth" -Value $gw -Force
                $script:Config | Add-Member -MemberType NoteProperty -Name "PathMaxHops" -Value $ph -Force
                $script:Config | Add-Member -MemberType NoteProperty -Name "PathSamples" -Value $ps -Force
                Save-Config $script:Config
                Write-Host "`n  [OK] GraphWidth=$gw MaxHops=$ph Samples=$ps" -ForegroundColor Green
                Start-Sleep -Milliseconds 800
            }
            elseif ($key -eq "0" -or $key -eq "`r") {
                break
            }
        } catch {
            Write-DebugLog "Ошибка в меню настроек: $_" "ERROR"
            # Ошибка не выводится в консоль, чтобы не пугать юзера, а пишется в лог
        }
    }
}

function Copy-ProxyConfigSnapshot {
    return @{
        Enabled = [bool]$global:ProxyConfig.Enabled
        Type    = [string]$global:ProxyConfig.Type
        Host    = [string]$global:ProxyConfig.Host
        Port    = [int]$global:ProxyConfig.Port
        User    = [string]$global:ProxyConfig.User
        Pass    = [string]$global:ProxyConfig.Pass
    }
}

function Restore-ProxyConfigSnapshot($snap) {
    if (-not $snap) { return }
    $global:ProxyConfig.Enabled = $snap.Enabled
    $global:ProxyConfig.Type = $snap.Type
    $global:ProxyConfig.Host = $snap.Host
    $global:ProxyConfig.Port = $snap.Port
    $global:ProxyConfig.User = $snap.User
    $global:ProxyConfig.Pass = $snap.Pass
}

function Read-ProxyMenuDigitKey {
    while ($true) {
        $mk = Read-MenuKeyOrResize
        if ($mk.Resized) {
            return [PSCustomObject]@{ Kind = "Resize" }
        }
        if ($mk.Key -eq [ConsoleKey]::Escape) {
            return [PSCustomObject]@{ Kind = "Exit" }
        }
        $k = $mk.Key
        if ($k -ge [ConsoleKey]::D0 -and $k -le [ConsoleKey]::D9) {
            return [PSCustomObject]@{ Kind = "Digit"; Digit = [int]($k - [ConsoleKey]::D0) }
        }
        if ($k -ge [ConsoleKey]::NumPad0 -and $k -le [ConsoleKey]::NumPad9) {
            return [PSCustomObject]@{ Kind = "Digit"; Digit = [int]($k - [ConsoleKey]::NumPad0) }
        }
    }
}

function Invoke-ProxyMenuActivateHistoryIndex {
    param([int]$Index, [array]$History)

    $historyEntry = $History[$Index]
    Write-DebugLog "Show-ProxyMenu: Выбран прокси из истории [#$($Index + 1)]"
    if ($historyEntry -match '^(?i)(http|socks5)://(?:([^:]+):\*\*\*\*\*@)?([^:]+):(\d+)$') {
        $proto = $matches[1].ToUpper()
        $user = if ($matches[2]) { $matches[2] } else { "" }
        $proxyHost = $matches[3]
        $port = [int]$matches[4]
        $pass = ""
        if ($user) {
            Write-Host "`n  [i] Прокси с аутентификацией. Введите пароль (Esc — отмена):" -ForegroundColor Yellow
            [Console]::CursorVisible = $false
            $passInput = Read-MenuLineOrResize
            if ($passInput.Resized) {
                Show-ProxyMenu
                return
            }
            if ($passInput.Cancelled) {
                Write-Host "  [i] Отмена." -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 800
                Show-ProxyMenu
                return
            }
            $pass = $passInput.Text
            [Console]::CursorVisible = $false
        }
        $snapBefore = Copy-ProxyConfigSnapshot
        $global:ProxyConfig.Enabled = $true
        $global:ProxyConfig.Type = $proto
        $global:ProxyConfig.Host = $proxyHost
        $global:ProxyConfig.Port = $port
        $global:ProxyConfig.User = $user
        $global:ProxyConfig.Pass = $pass
        Write-Host "`n  [WAIT] Проверка работоспособности прокси..." -ForegroundColor Yellow
        $testResult = Test-ProxyQuick $global:ProxyConfig
        if ($testResult.Success) {
            Write-Host "  [OK] Прокси работает! (задержка: $($testResult.Latency) мс)" -ForegroundColor Green
            Write-Host "  [OK] Тип: $($global:ProxyConfig.Type)" -ForegroundColor Green
            if ($user) {
                Write-Host "  [OK] Аутентификация настроена" -ForegroundColor Green
            }
            Add-ToProxyHistory $global:ProxyConfig
            Save-Config $script:Config
            Start-Sleep -Seconds 2
            return
        }
        Restore-ProxyConfigSnapshot $snapBefore
        Save-Config $script:Config
        Write-Host "  [FAIL] Прокси НЕ РАБОТАЕТ: $($testResult.Error)" -ForegroundColor Red
        Write-Host "  [i] Предыдущие настройки прокси восстановлены." -ForegroundColor Gray
        Start-Sleep -Seconds 2
        Show-ProxyMenu
        return
    }
    Write-Host "`n  [FAIL] Не удалось распарсить запись истории." -ForegroundColor Red
    Start-Sleep -Seconds 2
    Show-ProxyMenu
}

function Invoke-ProxyMenuManualString {
    param([string]$RawInput)

    $userInput = $RawInput.Trim()
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        Write-Host "`n  [i] Пустой ввод — отмена." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        Show-ProxyMenu
        return
    }

    Write-DebugLog "Show-ProxyMenu: Парсинг нового прокси '$userInput'"

    $proxyType = "AUTO"
    $user = ""
    $pass = ""
    $proxyHost = ""
    $port = 0

    if ($userInput -match '^(?i)(http|socks5)://') {
        $protocol = $matches[1].ToUpper()
        $proxyType = $protocol
        $userInput = $userInput -replace '^(?i)(http|socks5)://', ''
        Write-DebugLog "Show-ProxyMenu: Обнаружен протокол $proxyType, остаток = '$userInput'"
    }

    if ($userInput -match '^([^@]+)@') {
        $authPart = $matches[1]
        $userInput = $userInput -replace '^[^@]+@', ''
        Write-DebugLog "Show-ProxyMenu: Обнаружена аутентификация, authPart = '$authPart'"
        if ($authPart -match '^([^:]+):(.+)$') {
            $user = $matches[1]
            $pass = $matches[2]
            Write-DebugLog "Show-ProxyMenu: User = '$user', Pass = '***'"
        } else {
            Write-DebugLog "Show-ProxyMenu: Ошибка формата аутентификации"
            Write-Host "`n  [FAIL] Неверный формат аутентификации! Используйте user:pass@host:port" -ForegroundColor Red
            Start-Sleep -Seconds 3
            Show-ProxyMenu
            return
        }
    }

    $lastColon = $userInput.LastIndexOf(':')
    if ($lastColon -le 0) {
        Write-DebugLog "Show-ProxyMenu: Не найдено двоеточие в '$userInput'"
        Write-Host "`n  [FAIL] Неверный формат! Используйте host:port (например 127.0.0.1:1080)" -ForegroundColor Red
        Start-Sleep -Seconds 3
        Show-ProxyMenu
        return
    }

    $proxyHost = $userInput.Substring(0, $lastColon)
    $portStr = $userInput.Substring($lastColon + 1)

    Write-DebugLog "Show-ProxyMenu: Host = '$proxyHost', PortStr = '$portStr'"

    if (-not [int]::TryParse($portStr, [ref]$port)) {
        Write-DebugLog "Show-ProxyMenu: Не удалось распарсить порт"
        Write-Host "`n  [FAIL] Неверный формат порта! Порт должен быть числом (1-65535)" -ForegroundColor Red
        Start-Sleep -Seconds 3
        Show-ProxyMenu
        return
    }

    if ($port -lt 1 -or $port -gt 65535) {
        Write-DebugLog "Show-ProxyMenu: Порт вне диапазона: $port"
        Write-Host "`n  [FAIL] Порт должен быть в диапазоне 1-65535" -ForegroundColor Red
        Start-Sleep -Seconds 3
        Show-ProxyMenu
        return
    }

    if ([string]::IsNullOrEmpty($proxyHost)) {
        Write-DebugLog "Show-ProxyMenu: Пустой хост"
        Write-Host "`n  [FAIL] Хост не указан" -ForegroundColor Red
        Start-Sleep -Seconds 3
        Show-ProxyMenu
        return
    }

    Write-DebugLog "Show-ProxyMenu: Парсинг успешен! Host='$proxyHost', Port=$port, Type=$proxyType, User='$user'"

    Write-Host "`n  [WAIT] Проверка работоспособности прокси..." -ForegroundColor Yellow

    if ($proxyType -eq "AUTO") {
        Write-DebugLog "Show-ProxyMenu: Определяем тип прокси для $proxyHost`:$port"
        $detected = Detect-ProxyType $proxyHost $port
        if ($detected.Type -eq "UNKNOWN") {
            Write-Host "`n  [FAIL] Не удалось определить тип прокси. Укажите явно: http://$proxyHost`:$port или socks5://$proxyHost`:$port" -ForegroundColor Red
            Start-Sleep -Seconds 3
            Show-ProxyMenu
            return
        }
        $proxyType = $detected.Type
        Write-DebugLog "Show-ProxyMenu: Определен тип = $proxyType"
    }

    $snapBefore = Copy-ProxyConfigSnapshot

    $global:ProxyConfig.Enabled = $true
    $global:ProxyConfig.Type = $proxyType
    $global:ProxyConfig.Host = $proxyHost
    $global:ProxyConfig.Port = $port
    $global:ProxyConfig.User = $user
    $global:ProxyConfig.Pass = $pass

    $testResult = Test-ProxyQuick $global:ProxyConfig

    if ($testResult.Success) {
        Write-Host "  [OK] Прокси работает! (задержка: $($testResult.Latency) мс)" -ForegroundColor Green
        Write-Host "  [OK] Тип: $($global:ProxyConfig.Type)" -ForegroundColor Green
        if ($global:ProxyConfig.User) {
            Write-Host "  [OK] Аутентификация настроена" -ForegroundColor Green
        }
        Add-ToProxyHistory $global:ProxyConfig
        Save-Config $script:Config
        Start-Sleep -Seconds 2
    } else {
        Restore-ProxyConfigSnapshot $snapBefore
        Save-Config $script:Config
        Write-Host "  [FAIL] Прокси НЕ РАБОТАЕТ: $($testResult.Error)" -ForegroundColor Red
        Write-Host "  [i] Предыдущие настройки восстановлены. Проверьте адрес, порт или укажите тип явно (socks5://…)." -ForegroundColor Gray
        Start-Sleep -Seconds 3
        Show-ProxyMenu
    }
}

function Show-ProxyMenu {
    [Console]::Clear()
    $w = [Console]::WindowWidth
    if ($w -gt 100) { $w = 100 }
    $line = "═" * $w
    $dash = "─" * $w

    $history = @($script:Config.ProxyHistory)
    $histBase = 5
    $maxChoice = 4 + $history.Count

    Write-Host "`n $line" -ForegroundColor Cyan
    Write-Host (Get-PaddedCenter "НАСТРОЙКА ПРОКСИ" $w) -ForegroundColor Yellow
    Write-Host " $line" -ForegroundColor Cyan

    if ($global:ProxyConfig.Enabled) {
        Write-Host "`n  ТЕКУЩИЙ ПРОКСИ: " -NoNewline -ForegroundColor White
        Write-Host "$($global:ProxyConfig.Type)://" -NoNewline -ForegroundColor Green
        if ($global:ProxyConfig.User) {
            Write-Host "$($global:ProxyConfig.User):*****@" -NoNewline -ForegroundColor DarkYellow
        }
        Write-Host "$($global:ProxyConfig.Host):$($global:ProxyConfig.Port)" -ForegroundColor Green
    } else {
        Write-Host "`n  ТЕКУЩИЙ ПРОКСИ: " -NoNewline -ForegroundColor White
        Write-Host "ОТКЛЮЧЕН" -ForegroundColor Red
    }

    Write-Host "`n $dash" -ForegroundColor Gray
    Write-Host "  ДЕЙСТВИЯ:" -ForegroundColor White
    Write-Host "    1 — Проверить текущий прокси (полный тест)" -ForegroundColor Gray
    Write-Host "    2 — Выключить прокси и сбросить адрес" -ForegroundColor Gray
    Write-Host "    3 — Очистить историю (подтверждение Y/N)" -ForegroundColor Gray
    Write-Host "    4 — Ввести новый адрес прокси" -ForegroundColor Gray

    if ($history.Count -gt 0) {
        Write-Host "`n  ИЗ ИСТОРИИ:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $history.Count; $i++) {
            $mn = $histBase + $i
            $suffix = if ($i -eq 0) { "  (последний)" } else { "" }
            Write-Host "    $mn — $($history[$i])$suffix" -ForegroundColor Gray
        }
    }

    Write-Host "`n  П.4: host:port · http://host:port · socks5://host:port · user:pass@host:port" -ForegroundColor DarkGray
    Write-Host "  Пример: " -NoNewline -ForegroundColor DarkGray
    Write-Host "127.0.0.1:1080" -ForegroundColor Cyan -NoNewline
    Write-Host " (SOCKS), " -NoNewline -ForegroundColor DarkGray
    Write-Host ":8080" -ForegroundColor Cyan -NoNewline
    Write-Host " часто HTTP" -ForegroundColor DarkGray

    Write-Host "`n    0 или Esc — выход в главное меню" -ForegroundColor DarkGray

    Write-Host "`n $dash" -ForegroundColor Gray

    Update-UiConsoleSnapshot
    [Console]::ForegroundColor = "White"
    [Console]::CursorVisible = $false
    Clear-KeyBuffer

    $rk = Read-ProxyMenuDigitKey
    if ($rk.Kind -eq "Resize") {
        Show-ProxyMenu
        return
    }
    if ($rk.Kind -eq "Exit") {
        Write-DebugLog "Show-ProxyMenu: выход по Esc"
        return
    }

    $d = $rk.Digit
    if ($d -eq 0) {
        return
    }

    if ($d -lt 1 -or $d -gt $maxChoice) {
        Write-Host "`n  [i] Нажмите цифру от 0 до $maxChoice." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        Show-ProxyMenu
        return
    }

    if ($d -eq 1) {
        if (-not $global:ProxyConfig.Enabled) {
            Write-Host "`n  [i] Сначала задайте прокси: пункт 4 или $($histBase)…$maxChoice из истории." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            Show-ProxyMenu
            return
        }
        Test-ProxyConnection
        Show-ProxyMenu
        return
    }

    if ($d -eq 2) {
        $global:ProxyConfig.Enabled = $false
        $global:ProxyConfig.User = ""
        $global:ProxyConfig.Pass = ""
        $global:ProxyConfig.Host = ""
        $global:ProxyConfig.Port = 0
        $global:ProxyConfig.Type = "HTTP"
        Write-Host "`n  [OK] Прокси выключен, адрес сброшен." -ForegroundColor Green
        Save-Config $script:Config
        Start-Sleep -Seconds 1
        return
    }

    if ($d -eq 3) {
        if ($history.Count -eq 0) {
            Write-Host "`n  [i] История уже пуста." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            Show-ProxyMenu
            return
        }
        Write-Host "`n  Очистить всю историю ($($history.Count) записей)?  Y — да / N — нет " -ForegroundColor Yellow
        Clear-KeyBuffer
        Update-UiConsoleSnapshot
        $confirmed = $false
        while ($true) {
            $mk = Read-MenuKeyOrResize
            if ($mk.Resized) {
                Show-ProxyMenu
                return
            }
            $ch = [string]$mk.KeyChar
            if ($ch -eq "y" -or $ch -eq "Y") {
                $confirmed = $true
                break
            }
            if ($ch -eq "n" -or $ch -eq "N" -or $mk.Key -eq "Escape") {
                break
            }
        }
        if (-not $confirmed) {
            Write-Host "  [i] Очистка отменена." -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
            Show-ProxyMenu
            return
        }
        $script:Config.ProxyHistory = @()
        Save-Config $script:Config
        Write-Host "  [OK] История прокси очищена." -ForegroundColor Green
        Start-Sleep -Seconds 1
        Show-ProxyMenu
        return
    }

    if ($d -eq 4) {
        Write-Host "`n $dash" -ForegroundColor Gray
        Write-Host "  Введите адрес прокси (Esc — отмена):" -ForegroundColor White
        Write-Host "  > " -NoNewline -ForegroundColor Yellow
        $lineInput = Read-MenuLineOrResize
        if ($lineInput.Resized) {
            Show-ProxyMenu
            return
        }
        if ($lineInput.Cancelled) {
            Write-Host "`n  [i] Отмена." -ForegroundColor DarkGray
            Start-Sleep -Milliseconds 600
            Show-ProxyMenu
            return
        }
        Invoke-ProxyMenuManualString $lineInput.Text
        return
    }

    $histIdx = $d - $histBase
    Invoke-ProxyMenuActivateHistoryIndex -Index $histIdx -History $history
}
function Detect-ProxyType {
    param([string]$targetHost, [int]$targetPort)

    $result = @{
        Type = "UNKNOWN"
        User = ""
        Pass = ""
    }

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($targetHost, $targetPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(2000)) {
            return $result
        }
        $tcp.EndConnect($async)
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 2000
        $stream.WriteTimeout = 2000

        # Пробуем SOCKS5
        try {
            $stream.Write([byte[]]@(0x05, 0x01, 0x00), 0, 3)
            $buf = New-Object byte[] 2
            $read = $stream.Read($buf, 0, 2)
            if ($read -eq 2 -and $buf[0] -eq 0x05) {
                $result.Type = "SOCKS5"
                return $result
            }
        } catch {
            # Не SOCKS5, пробуем HTTP
        }

        # Пробуем HTTP CONNECT
        try {
            $req = [Text.Encoding]::ASCII.GetBytes("CONNECT google.com:80 HTTP/1.1`r`nHost: google.com:80`r`n`r`n")
            $stream.Write($req, 0, $req.Length)
            $buf = New-Object byte[] 128
            $read = $stream.Read($buf, 0, 128)
            $response = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
            if ($response -match "HTTP/1.[01]\s+200") {
                $result.Type = "HTTP"
                return $result
            }
        } catch {
            # Не HTTP
        }

    } catch {
        # Ошибка подключения
    } finally {
        if ($tcp) { $tcp.Close() }
    }

    return $result
}

function Test-ProxyQuick {
    param($ProxyConfig)

    $result = @{
        Success = $false
        Latency = $null
        Error = ""
    }

    if ([string]::IsNullOrEmpty($ProxyConfig.Host) -or $ProxyConfig.Port -le 0) {
        $result.Error = "Прокси не настроен (хост/порт пуст)"
        return $result
    }

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $conn = Connect-ThroughProxy "google.com" 80 $ProxyConfig 5000
        if ($conn) {
            $result.Latency = $sw.ElapsedMilliseconds
            $result.Success = $true
            $conn.Tcp.Close()
        } else {
            $result.Error = "Не удалось установить туннель"
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-DebugLog "Test-ProxyQuick error: $errMsg"
        if ($errMsg -match "таймаут|timeout") {
            $result.Error = "Таймаут подключения (возможно, порт закрыт или прокси не отвечает)"
        } elseif ($errMsg -match "отказано|refused") {
            $result.Error = "Соединение отклонено (проверьте порт, возможно, прокси не работает)"
        } elseif ($errMsg -match "аутентификация|authentication") {
            $result.Error = "Ошибка аутентификации (неверный логин/пароль)"
        } elseif ($errMsg -match "не удалось разрешить|unable to resolve") {
            $result.Error = "Не удалось разрешить имя хоста прокси"
        } else {
            $result.Error = $errMsg
        }
    }

    return $result
}

function Wait-TcpBeginConnectWithStatus([System.Net.Sockets.TcpClient]$Tcp, [System.IAsyncResult]$Ar, [int]$TimeoutMs, [string]$DetailLabel) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Ar.IsCompleted) {
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        $null = $Ar.AsyncWaitHandle.WaitOne(90)
    }
    return $true
}

function Test-ProxyConnection {
    Write-DebugLog "Test-ProxyConnection: расширенный тест прокси"
    [Console]::CursorVisible = $false
    if (-not $global:ProxyConfig.Enabled) {
        Write-Host "`n  [FAIL] Включите прокси в меню [P] или введите адрес." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }
    $pc = $global:ProxyConfig
    [Console]::Clear()
    $w = [Console]::WindowWidth
    if ($w -gt 100) { $w = 100 }
    $line = "─" * $w
    Write-Host "`n $line" -ForegroundColor Cyan
    Write-Host (Get-PaddedCenter "ПРОВЕРКА ПРОКСИ" $w) -ForegroundColor Yellow
    Write-Host " $line" -ForegroundColor Cyan
    Write-Host "`n  $($pc.Type) $($pc.Host):$($pc.Port)" -ForegroundColor Green

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("══ ПРОВЕРКА ПРОКСИ ══")
    $lines.Add("Тип: $($pc.Type)  Адрес: $($pc.Host):$($pc.Port)  Логин: $(if ($pc.User) { $pc.User } else { '(нет)' })")
    $lines.Add("")

    # 1) TCP до хоста прокси (с «живым» ожиданием)
    $swTcp = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Host "`n  [1/4] TCP до прокси..." -ForegroundColor Cyan
        $tcpP = New-Object System.Net.Sockets.TcpClient
        $arP = $tcpP.BeginConnect($pc.Host, $pc.Port, $null, $null)
        if (-not (Wait-TcpBeginConnectWithStatus $tcpP $arP 4000 "1/4 TCP до прокси")) {
            try { $tcpP.Close() } catch { }
            throw "Таймаут TCP до прокси (4 c)"
        }
        $tcpP.EndConnect($arP)
        $swTcp.Stop()
        $lines.Add("[OK] TCP до прокси: $($swTcp.ElapsedMilliseconds) мс")
        $tcpP.Close()
        Write-Host "       OK $($swTcp.ElapsedMilliseconds) ms" -ForegroundColor Green
        Start-Sleep -Milliseconds 120
    } catch {
        $lines.Add("[FAIL] TCP до прокси: $($_.Exception.Message)")
        Show-ProxyTestResultPanel $lines $false
        return
    }

    # 2) Туннель :80
    Write-Host "  [2/4] Туннель google.com:80..." -ForegroundColor Cyan
    $q80 = Test-ProxyQuick $pc
    if ($q80.Success) {
        $lines.Add("[OK] Туннель google.com:80 — $($q80.Latency) мс")
        Write-Host "       OK $($q80.Latency) ms" -ForegroundColor Green
    } else {
        $lines.Add("[FAIL] Туннель google.com:80 — $($q80.Error)")
        Write-Host "       FAIL $($q80.Error)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 150

    # 3) Туннель :443
    $ok443 = $false
    Write-Host "  [3/4] Туннель google.com:443..." -ForegroundColor Cyan
    $sw443 = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $c443 = Connect-ThroughProxy "google.com" 443 $pc 7000
        if ($c443 -and $c443.Tcp) {
            $sw443.Stop()
            $ok443 = $true
            $lines.Add("[OK] Туннель google.com:443 — $($sw443.ElapsedMilliseconds) мс")
            Write-Host "       OK $($sw443.ElapsedMilliseconds) ms" -ForegroundColor Green
            try { $c443.Tcp.Close() } catch { }
        } else {
            $lines.Add("[FAIL] Туннель google.com:443 — нет сокета после CONNECT")
            Write-Host "       FAIL нет сокета после CONNECT" -ForegroundColor Red
        }
    } catch {
        $lines.Add("[FAIL] Туннель google.com:443 — $($_.Exception.Message)")
        Write-Host "       FAIL $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 150

    # 4) HTTP как у GEO
    Write-Host "  [4/4] HTTP через прокси..." -ForegroundColor Cyan
    try {
        $swHttp = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-WebRequestViaProxy "http://www.gstatic.com/generate_204" "GET" 5000
        $swHttp.Stop()
        if ($swHttp.ElapsedMilliseconds -ge 4800) {
            $lines.Add("[WARN] HTTP через прокси: очень долго ($($swHttp.ElapsedMilliseconds) мс)")
            Write-Host "       WARN долго $($swHttp.ElapsedMilliseconds) ms" -ForegroundColor Yellow
        } else {
            $lines.Add("[OK] HTTP через прокси (gstatic 204) — $($swHttp.ElapsedMilliseconds) мс")
            Write-Host "       OK $($swHttp.ElapsedMilliseconds) ms" -ForegroundColor Green
        }
    } catch {
        $lines.Add("[FAIL] HTTP через прокси: $($_.Exception.Message)")
        Write-Host "       FAIL $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 200

    $allCriticalOk = $q80.Success -and $ok443
    Show-ProxyTestResultPanel $lines $allCriticalOk
}

function Show-ProxyTestResultPanel {
    param([System.Collections.Generic.List[string]]$Lines, [bool]$OverallOk)
    $oldBufH = [Console]::BufferHeight
    try { if ([Console]::BufferHeight -lt 80) { [Console]::BufferHeight = 80 } } catch {}
    [Console]::Clear()
    [Console]::CursorVisible = $false
    $w = [Console]::WindowWidth
    if ($w -gt 100) { $w = 100 }
    $line = "─" * $w
    Write-Host "`n $line" -ForegroundColor Cyan
    Write-Host (Get-PaddedCenter "РЕЗУЛЬТАТ ТЕСТА ПРОКСИ" $w) -ForegroundColor $(if ($OverallOk) { "Green" } else { "Yellow" })
    Write-Host " $line" -ForegroundColor Cyan
    foreach ($ln in $Lines) {
        if ($ln -match '^\[OK\]') { Write-Host " $ln" -ForegroundColor Green }
        elseif ($ln -match '^\[FAIL\]') { Write-Host " $ln" -ForegroundColor Red }
        elseif ($ln -match '^\[WARN\]|^\[i\]') { Write-Host " $ln" -ForegroundColor DarkYellow }
        elseif ($ln -match '^═') { Write-Host "`n $ln" -ForegroundColor White }
        else { Write-Host " $ln" -ForegroundColor Gray }
    }
    Write-Host "`n $line" -ForegroundColor Gray
    Write-Host (Get-PaddedCenter "Любая клавиша — назад" $w) -ForegroundColor Gray
    Clear-KeyBuffer
    Update-UiConsoleSnapshot
    $panelKey = Read-MenuKeyOrResize
    if ($panelKey.Resized) {
        Show-ProxyTestResultPanel $Lines $OverallOk
        return
    }
    try { [Console]::BufferHeight = $oldBufH } catch {}
}

function Show-HelpMenu {
    param([int]$ResumePage = 0)

    Write-DebugLog "Show-HelpMenu: Справка (возврат на стр. $ResumePage)..."

    $oldBufH = [Console]::BufferHeight
    try {
        $needBuf = [Math]::Max(100, [Console]::WindowHeight + 60)
        if ([Console]::BufferHeight -lt $needBuf) { [Console]::BufferHeight = $needBuf }
    } catch {}

    $totalPages = 5
    $page = [Math]::Max(0, [Math]::Min($ResumePage, $totalPages - 1))

    while ($true) {
        [Console]::Clear()
        [Console]::CursorVisible = $false

        $w = [Console]::WindowWidth
        if ($w -gt 108) { $w = 108 }
        $line = "─" * $w

        Write-Host "`n $($line)" -ForegroundColor Gray
        Write-Host "   YT-DPI v$scriptVersion — справка  (страница $($page + 1) / $totalPages)" -ForegroundColor Cyan
        Write-Host " $($line)" -ForegroundColor Gray

        switch ($page) {
            0 {
                Write-Host "`n [ ЧТО ДЕЛАЕТ ПРОГРАММА ]" -ForegroundColor White
                Write-Host "   Параллельно проверяет список доменов: TCP/HTTP на порту 80, TLS 1.2 и TLS 1.3 на 443" -ForegroundColor Gray
                Write-Host "   с реальным именем хоста (SNI). Это диагностика сети/DPI, не обход блокировок." -ForegroundColor Gray

                Write-Host "`n [ ГОРЯЧИЕ КЛАВИШИ (главный экран) ]" -ForegroundColor White
                Write-Host "   ENTER     " -ForegroundColor Yellow -NoNewline; Write-Host " — полное сканирование таблицы (после проверки сети)." -ForegroundColor Gray
                Write-Host "   S         " -ForegroundColor Yellow -NoNewline; Write-Host " — настройки: IP (1), кэш (2), TLS (3), лог (4), полные идентификаторы в логе (5)." -ForegroundColor Gray
                Write-Host "   P         " -ForegroundColor Yellow -NoNewline; Write-Host " — меню прокси (цифры 1–4 и история с 5, 0/Esc — выход)." -ForegroundColor Gray
                Write-Host "   D         " -ForegroundColor Yellow -NoNewline; Write-Host " — DNS: системный резолв vs DoH." -ForegroundColor Gray
                Write-Host "   G         " -ForegroundColor Yellow -NoNewline; Write-Host " — PATH: ICMP mtr-lite (без прокси/VPN; схлоп — экран)." -ForegroundColor Gray
                Write-Host "   E         " -ForegroundColor Yellow -NoNewline; Write-Host " — EXTRA: полный блок DNS/QUIC/TCP16/IP-SNI + recommendations." -ForegroundColor Gray
                Write-Host "   U         " -ForegroundColor Yellow -NoNewline; Write-Host " — проверка и загрузка обновления с GitHub." -ForegroundColor Gray
                Write-Host "   R         " -ForegroundColor Yellow -NoNewline; Write-Host " — сохранить отчёт в файл YT-DPI_Report.txt (если скана не было — пустой шаблон)." -ForegroundColor Gray
                Write-Host "   H         " -ForegroundColor Yellow -NoNewline; Write-Host " — эта справка." -ForegroundColor Gray
                Write-Host "   Q / ESC   " -ForegroundColor Yellow -NoNewline; Write-Host " — выход (сохраняется конфиг)." -ForegroundColor Gray
                Write-Host "`n   Во время скана следуйте подсказкам в строке статуса (прерывание, повтор и т.д.)." -ForegroundColor DarkGray
            }
            1 {
                Write-Host "`n [ КОЛОНКИ ТАБЛИЦЫ ]" -ForegroundColor White
                Write-Host "   № / TARGET — номер строки и проверяемый домен." -ForegroundColor Gray
                Write-Host "   IP — резолв IPv4/IPv6 по настройкам; [ PROXIED ] при скане через прокси; DNS_ERR — ошибка DNS." -ForegroundColor Gray
                Write-Host "   HTTP — доступность порта 80 (не «веб-страница», а именно TCP до сервера)." -ForegroundColor Gray
                Write-Host "   T12 / T13 — результат TLS-handshake для версии 1.2 и «современного» клиента (1.3+)." -ForegroundColor Gray
                Write-Host "   LAT — задержка HTTP-проверки в миллисекундах (грубый ping-подобный показатель)." -ForegroundColor Gray
                Write-Host "   RESULT — итоговый вердикт по комбинации HTTP+TLS (см. след. страницу)." -ForegroundColor Gray

                Write-Host "`n [ КОДЫ В ЯЧЕЙКАХ HTTP / TLS ]" -ForegroundColor White
                Write-Host "   OK      " -ForegroundColor Green -NoNewline; Write-Host " — проверка прошла (для TLS: рукопожатие до ответа сервера)." -ForegroundColor Gray
                Write-Host "   ERR     " -ForegroundColor Red -NoNewline; Write-Host " — порт 80 недоступен; TLS дальше не проверяются (показывается ---)." -ForegroundColor Gray
                Write-Host "   RST     " -ForegroundColor Red -NoNewline; Write-Host " — соединение сброшено (частая картина при DPI с TCP RST)." -ForegroundColor Gray
                Write-Host "            В отчёте/JSON: RST_CH = сброс на ClientHello; RST_POST = после handshake." -ForegroundColor DarkGray
                Write-Host "   DRP     " -ForegroundColor Red -NoNewline; Write-Host " — обрыв/таймаут/«чёрная дыра» без нормального ответа." -ForegroundColor Gray
                Write-Host "   PRX_ERR " -ForegroundColor Red -NoNewline; Write-Host " — ошибка туннеля SOCKS к цели (в колонке T13 при прокси)." -ForegroundColor Gray
                Write-Host "   N/A     " -ForegroundColor DarkGray -NoNewline; Write-Host " — TLS 1.3 не применим/не получилось классифицировать (редко в таблице)." -ForegroundColor Gray
                Write-Host "   ---     " -ForegroundColor DarkGray -NoNewline; Write-Host " — значение ещё не получено или проверка пропущена (например после ERR по HTTP)." -ForegroundColor Gray
            }
            2 {
                Write-Host "`n [ ВЕРДИКТЫ (RESULT) ]" -ForegroundColor White
                Write-Host "   AVAILABLE   " -ForegroundColor Green -NoNewline
                Write-Host " — оба TLS (1.2 и 1.3) в состоянии OK; доступ к узлу по HTTPS выглядит нормальным." -ForegroundColor Gray
                Write-Host "   THROTTLED   " -ForegroundColor Yellow -NoNewline
                Write-Host " — один из TLS OK, второй даёт RST/DRP: типичный частичный DPI или деградация одного пути." -ForegroundColor Gray
                Write-Host "   DPI RESET   " -ForegroundColor Red -NoNewline
                Write-Host " — хотя бы один TLS завершился кодом RST (жёсткий сброс)." -ForegroundColor Gray
                Write-Host "   DPI BLOCK   " -ForegroundColor Red -NoNewline
                Write-Host " — есть DRP без сценария выше (обрыв/таймаут на TLS)." -ForegroundColor Gray
                Write-Host "   IP BLOCK    " -ForegroundColor Red -NoNewline
                Write-Host " — HTTP недоступен или оба TLS не дали рабочей картины (смотрите ячейки)." -ForegroundColor Gray
                Write-Host "   TIMEOUT     " -ForegroundColor Red -NoNewline
                Write-Host " — строка не успела завершиться в лимите времени скана." -ForegroundColor Gray
                Write-Host "   UNKNOWN     " -ForegroundColor DarkGray -NoNewline
                Write-Host " — внутренняя ошибка воркера или неожиданное состояние." -ForegroundColor Gray
                Write-Host "   IDLE        " -ForegroundColor DarkGray -NoNewline
                Write-Host " — строка ещё не сканировалась (начальное состояние)." -ForegroundColor Gray

                Write-Host "`n [ EXTRA DIAG 3.0 (после ENTER) ]" -ForegroundColor White
                Write-Host "   QUIC UDP:443, TCP 16–20KB drop, IP vs SNI (+ DNS тоже в EXTRA). Отдельный DNS-режим: клавиша D." -ForegroundColor Gray
                Write-Host "   R → TXT + JSON. CLI: --batch [--json path] [--report path] [--no-extras]." -ForegroundColor Gray

                Write-Host "`n [ КАК ЭТО ЧИТАТЬ ПРАКТИЧЕСКИ ]" -ForegroundColor White
                Write-Host "   Сначала HTTP: если ERR — проблема шире TLS (маршрут, IP, прокси, «падает» порт 80)." -ForegroundColor Gray
                Write-Host "   Если HTTP OK, смотрите T12 и T13: оба OK — хорошо; расхождение — смотрите THROTTLED/DPI*." -ForegroundColor Gray
                Write-Host "   Вердикт обобщает таблицу; детали всегда в отдельных ячейках и в отчёте (R)." -ForegroundColor Gray
            }
            3 {
                Write-Host "`n [ DNS (D) / PATH (G) / EXTRA (E) — UI 3.0 ]" -ForegroundColor White
                Write-Host "   D — system DNS vs DoH для youtube/googlevideo/ytimg (+ CDN)." -ForegroundColor Gray
                Write-Host "   G — PATH mtr-lite: ICMP TTL hops. Не работает через прокси/VPN (отказ + пояснение)." -ForegroundColor Gray
                Write-Host "   E — полный EXTRA DIAG и recommendations (скриншот)." -ForegroundColor Gray
                Write-Host "`n   Подсказки после EXTRA — один раз в STATUS. Детали: [E]. Настройки: [S] 9 / A / B." -ForegroundColor Gray
                Write-Host "   Deep Trace удалён; PATH не делает TLS на каждом хопе." -ForegroundColor DarkGray
            }
            4 {
                Write-Host "`n [ МЕНЮ ПРОКСИ (P) ]" -ForegroundColor White
                Write-Host "   Введите строку прокси (см. подсказки в самом меню) или номер из истории." -ForegroundColor Gray
                Write-Host "   Цифры: 1 — тест, 2 — выкл., 3 — очистить историю, 4 — новый адрес; 5+ — слоты истории; 0/Esc — выход." -ForegroundColor Gray
                Write-Host "   Отдельной клавиши «T» на главном экране нет — тест прокси только из меню P." -ForegroundColor DarkGray

                Write-Host "`n [ НАСТРОЙКИ (S) ]" -ForegroundColor White
                Write-Host "   1 — IPv6 приоритет / только IPv4; 2 — сброс DNS и GEO-кэша; 3 — режим скана TLS (Auto / только 1.2 / только 1.3)." -ForegroundColor Gray
                Write-Host "   4 — запись отладки в YT-DPI_Debug.log (рядом со скриптом); плюс можно включить через YT_DPI_DEBUG=1." -ForegroundColor Gray
                Write-Host "   5 — полные ПК/пользователь/пути в заголовке лога (по умолчанию ВЫКЛ = обезличено); или YT_DPI_DEBUG_IDENTIFIERS=1." -ForegroundColor Gray
                Write-Host "   6–7 — targets.txt; 9/A/B — LAT bars, charset, PATH params." -ForegroundColor Gray
                Write-Host "   Режим TLS и флаги отладки сохраняются в конфиг; лог активен, если ВКЛ в меню или задана переменная окружения." -ForegroundColor DarkGray

                Write-Host "`n [ ОБНОВЛЕНИЕ (U) ]" -ForegroundColor White
                Write-Host "   Сверка версии с релизом на GitHub и замена локальных файлов по подтверждению (Y/N)." -ForegroundColor Gray

                Write-Host "`n [ TLS, БРАУЗЕР И ЛОЖНЫЕ СРАБАТЫВАНИЯ ]" -ForegroundColor White
                Write-Host "   TLS 1.3 в браузерах может использовать пост-квантовые дополнения (например Kyber)." -ForegroundColor Gray
                Write-Host "   Если картина нестабильна, попробуйте отключить эксперимент: " -ForegroundColor Gray -NoNewline
                Write-Host "chrome://flags/#enable-tls13-kyber" -ForegroundColor Cyan
                Write-Host "   Сканер не открывает сайт в браузере — только сетевой уровень; различайте «сайт тормозит»" -ForegroundColor Gray
                Write-Host "   (CDN, GGC, контент) и «TLS режется по имени» (DPI по SNI)." -ForegroundColor Gray

                Write-Host "`n [ БЫСТРЫЕ ОТВЕТЫ ]" -ForegroundColor White
                Write-Host "   THROTTLED + живой YouTube — часто помогает обход DPI или смена сети/прокси." -ForegroundColor Gray
                Write-Host "   Все строки IP BLOCK — проверьте интернет, VPN/прокси, DNS и что скан не ушёл в «пустой» кэш." -ForegroundColor Gray
                Write-Host "   Сохраняйте отчёт (R) перед тем как делиться логами в чатах поддержки." -ForegroundColor Gray
            }
        }

        Write-Host "`n $($line)" -ForegroundColor DarkGray
        Write-Host (Get-PaddedCenter "N / → / PgDn — далее    P / ← / PgUp — назад    Enter / Esc — закрыть" $w) -ForegroundColor DarkGray
        Write-Host " $($line)" -ForegroundColor DarkGray

        Clear-KeyBuffer
        Update-UiConsoleSnapshot
        $helpKey = Read-MenuKeyOrResize
        if ($helpKey.Resized) {
            try { [Console]::BufferHeight = $oldBufH } catch {}
            Show-HelpMenu -ResumePage $page
            return
        }

        $hk = $helpKey.Key
        $navNext = @([ConsoleKey]::N, [ConsoleKey]::RightArrow, [ConsoleKey]::DownArrow, [ConsoleKey]::PageDown)
        $navPrev = @([ConsoleKey]::P, [ConsoleKey]::LeftArrow, [ConsoleKey]::UpArrow, [ConsoleKey]::PageUp)

        if ($hk -in @([ConsoleKey]::Enter, [ConsoleKey]::Escape)) {
            break
        }
        elseif ($hk -in $navNext) {
            $page = ($page + 1) % $totalPages
        }
        elseif ($hk -in $navPrev) {
            $page = ($page - 1 + $totalPages) % $totalPages
        }
        else {
            # любая другая клавиша — выход (удобно при нестандартной раскладке)
            break
        }
    }

    try { [Console]::BufferHeight = $oldBufH } catch {}
}

function Add-ToProxyHistory {
    param($ProxyConfig)

    # Формируем строку для истории (без пароля)
    $entry = "$($ProxyConfig.Type)://"
    if ($ProxyConfig.User) {
        $entry += "$($ProxyConfig.User):*****@"
    }
    $entry += "$($ProxyConfig.Host):$($ProxyConfig.Port)"

    # Получаем текущую историю
    $history = @($script:Config.ProxyHistory)
    # Удаляем дубликат, если есть
    $history = $history | Where-Object { $_ -ne $entry }
    # Добавляем в начало
    $history = @($entry) + $history
    # Обрезаем до 5
    if ($history.Count -gt 5) { $history = $history[0..4] }
    $script:Config.ProxyHistory = $history
    Save-Config $script:Config
    Write-DebugLog "Proxy history updated: $entry"
}

# ====================================================================================
# РАБОЧИЙ ПОТОК
# ====================================================================================
$Worker = {
    param($Target, $ProxyConfig, $CONST, $DebugLogFile, $DEBUG_ENABLED, $DnsCache, $DnsCacheLock, $NetInfo, $IpPreference, $TlsMode, $DebugLogMutexName, [bool]$ParallelTlsFirstPass)

    function Write-DebugLog($msg, $level = "DEBUG") {
        if (-not $DEBUG_ENABLED) { return }
        $line = "[$(Get-Date -Format 'HH:mm:ss.fff')] [Worker $($Target)] [$($level)] $($msg)`r`n"
        $mtx = $null
        $got = $false
        try {
            try { $mtx = if ($DebugLogMutexName) { [System.Threading.Mutex]::OpenExisting($DebugLogMutexName) } else { $null } } catch { $mtx = $null }
            if ($mtx) {
                try { $got = $mtx.WaitOne([int]$CONST.Mutex.WaitMs) } catch { $got = $false }
            }
            if ($got) {
                [System.IO.File]::AppendAllText($DebugLogFile, $line, [System.Text.Encoding]::UTF8)
            } else {
                try { [System.IO.File]::AppendAllText($DebugLogFile, $line, [System.Text.Encoding]::UTF8) } catch { }
            }
        } catch { }
        finally {
            if ($got -and $mtx) { try { [void]$mtx.ReleaseMutex() } catch { } }
            if ($mtx) { try { $mtx.Dispose() } catch { } }
        }
    }

    # --- ВНУТРЕННИЕ ФУНКЦИИ ---
    function Connect-ThroughProxy {
        param($TargetHost, $TargetPort, $ProxyConfig, [int]$Timeout = $CONST.ProxyTimeout)
        if ([string]::IsNullOrEmpty($ProxyConfig.Host) -or $ProxyConfig.Port -le 0) {
            throw "Некорректная конфигурация прокси: хост='$($ProxyConfig.Host)', порт=$($ProxyConfig.Port)"
        }
        Write-DebugLog "Подключение через прокси $($ProxyConfig.Type) к $($TargetHost):$($TargetPort)"
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $asyn = $tcp.BeginConnect($ProxyConfig.Host, $ProxyConfig.Port, $null, $null)
            if (-not $asyn.AsyncWaitHandle.WaitOne($Timeout)) { throw "Таймаут подключения к прокси" }
            $tcp.EndConnect($asyn); $stream = $tcp.GetStream()
            $stream.ReadTimeout = $Timeout; $stream.WriteTimeout = $Timeout

            if ($ProxyConfig.Type -eq "SOCKS5") {
                Write-DebugLog "SOCKS5: начало рукопожатия"

                # === Определяем, какие методы аутентификации предложить ===
                $methods = @()
                if ($ProxyConfig.User -and $ProxyConfig.Pass) {
                    # Если есть логин/пароль, предлагаем сначала аутентификацию по паролю (0x02), затем без аутентификации (0x00)
                    $methods = @(0x02, 0x00)
                } else {
                    # Без аутентификации предлагаем только 0x00
                    $methods = @(0x00)
                }
                $greeting = [byte[]](@(0x05, $methods.Count) + $methods)
                $stream.Write($greeting, 0, $greeting.Length)

                # Читаем ответ сервера (2 байта: VER, METHOD)
                $resp = New-Object byte[] 2
                if ($stream.Read($resp, 0, 2) -ne 2) {
                    throw "SOCKS5: нет ответа на выбор метода"
                }
                if ($resp[0] -ne 0x05) {
                    throw "SOCKS5: неверная версия ответа (ожидалась 0x05, получена 0x$('{0:X2}' -f $resp[0]))"
                }

                $method = $resp[1]
                Write-DebugLog "SOCKS5: сервер выбрал метод аутентификации 0x$('{0:X2}' -f $method)"

                # === Обработка выбранного метода ===
                if ($method -eq 0x00) {
                    # Без аутентификации — ничего не делаем
                    Write-DebugLog "SOCKS5: аутентификация не требуется"
                }
                elseif ($method -eq 0x02) {
                    # Аутентификация по логину/паролю
                    if (-not $ProxyConfig.User -or -not $ProxyConfig.Pass) {
                        throw "SOCKS5: сервер требует логин/пароль, но они не указаны в настройках"
                    }
                    $u = [Text.Encoding]::UTF8.GetBytes($ProxyConfig.User)
                    $p = [Text.Encoding]::UTF8.GetBytes($ProxyConfig.Pass)
                    $authMsg = [byte[]](@(0x01, $u.Length) + $u + @($p.Length) + $p)
                    $stream.Write($authMsg, 0, $authMsg.Length)

                    $authResp = New-Object byte[] 2
                    if ($stream.Read($authResp, 0, 2) -ne 2) {
                        throw "SOCKS5: нет ответа на аутентификацию"
                    }
                    if ($authResp[0] -ne 0x01 -or $authResp[1] -ne 0x00) {
                        throw "SOCKS5: неверный логин/пароль (код $($authResp[1]))"
                    }
                    Write-DebugLog "SOCKS5: аутентификация успешна"
                }
                elseif ($method -eq 0xFF) {
                    throw "SOCKS5: сервер отверг все предложенные методы аутентификации (0xFF). Проверьте, требуется ли аутентификация."
                }
                else {
                    throw "SOCKS5: сервер выбрал неподдерживаемый метод аутентификации 0x$('{0:X2}' -f $method)"
                }

                # === Запрос на подключение к целевому хосту ===
                $addrType = 0x03   # domain name
                $hostBytes = [Text.Encoding]::UTF8.GetBytes($TargetHost)
                $req = [byte[]](@(0x05, 0x01, 0x00, $addrType, $hostBytes.Length) + $hostBytes + @([math]::Floor($TargetPort/256), ($TargetPort%256)))
                $stream.Write($req, 0, $req.Length)

                # Читаем ответ (минимум 10 байт)
                $resp = New-Object byte[] 10
                $read = 0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($read -lt 10 -and $sw.ElapsedMilliseconds -lt $Timeout) {
                    if ($stream.DataAvailable) {
                        $r = $stream.Read($resp, $read, 10 - $read)
                        if ($r -eq 0) { break }
                        $read += $r
                    } else { Start-Sleep -Milliseconds 20 }
                }
                if ($read -lt 10) { throw "SOCKS5: неполный ответ на запрос подключения" }
                if ($resp[0] -ne 0x05) { throw "SOCKS5: неверная версия в ответе на подключение" }
                if ($resp[1] -ne 0x00) {
                    $repCode = $resp[1]
                    $errorMap = @{
                        0x01 = "general failure"
                        0x02 = "connection not allowed"
                        0x03 = "network unreachable"
                        0x04 = "host unreachable"
                        0x05 = "connection refused"
                        0x06 = "TTL expired"
                        0x07 = "command not supported"
                        0x08 = "address type not supported"
                    }
                    $errText = if ($errorMap.ContainsKey($repCode)) { $errorMap[$repCode] } else { "unknown error 0x$('{0:X2}' -f $repCode)" }
                    throw "SOCKS5: сервер вернул ошибку - $errText"
                }
                Write-DebugLog "SOCKS5: маршрут установлен успешно"
                return @{ Tcp = $tcp; Stream = $stream }
            }
            elseif ($ProxyConfig.Type -eq "HTTP") {
                $hdr = "CONNECT ${TargetHost}:$TargetPort HTTP/1.1`r`nHost: ${TargetHost}:$TargetPort`r`n"
                if ($ProxyConfig.User -and $ProxyConfig.Pass) {
                    $authBytes = [Text.Encoding]::ASCII.GetBytes("$($ProxyConfig.User):$($ProxyConfig.Pass)")
                    $hdr += "Proxy-Authorization: Basic $([Convert]::ToBase64String($authBytes))`r`n"
                }
                $hdr += "`r`n"
                $reqBytes = [Text.Encoding]::ASCII.GetBytes($hdr)
                $stream.Write($reqBytes, 0, $reqBytes.Length)

                $swRead = [System.Diagnostics.Stopwatch]::StartNew()
                $response = ""
                $buf = New-Object byte[] 1024
                while ($swRead.ElapsedMilliseconds -lt $Timeout) {
                    if ($stream.DataAvailable) {
                        $r = $stream.Read($buf, 0, 1024)
                        if ($r -le 0) { break }
                        $response += [Text.Encoding]::ASCII.GetString($buf, 0, $r)
                        if ($response -match "`r`n`r`n") { break }
                    } else { Start-Sleep -Milliseconds 20 }
                }

                if ($response -match '(?m)HTTP/1\.\d\s+200') {
                    Write-DebugLog "HTTP CONNECT tunnel OK -> ${TargetHost}:$TargetPort"
                    return @{ Tcp = $tcp; Stream = $stream }
                }

                $snip = if ($response.Length -gt 160) { $response.Substring(0, 160) + "..." } else { $response }
                throw "HTTP CONNECT не 200: $snip"
            }
            else {
                throw "Неподдерживаемый тип прокси для туннеля: $($ProxyConfig.Type)"
            }
        } catch {
            if($tcp){$tcp.Close()}
            Write-DebugLog "Ошибка прокси: $($_.Exception.Message)" "WARN"
            throw $_
        }
    }

    function Set-Verdict-DualTlsCells {
        param(
            [string]$Cell12,
            [string]$Cell13,
            [string]$RstPhase12 = $null,
            [string]$RstPhase13 = $null
        )
        # RST during ClientHello is classic DPI SNI reset — prefer DPI RESET over THROTTLED.
        if ($RstPhase12 -eq "RST_CH" -or $RstPhase13 -eq "RST_CH") {
            return @{ Verdict = "DPI RESET"; Color = "Red" }
        }
        $t12Ok = ($Cell12 -eq "OK")
        $t13Ok = ($Cell13 -eq "OK")
        $t12Blocked = ($Cell12 -eq "RST" -or $Cell12 -eq "DRP")
        $t13Blocked = ($Cell13 -eq "RST" -or $Cell13 -eq "DRP")
        if ($t12Ok -and $t13Ok) { return @{ Verdict = "AVAILABLE"; Color = "Green" } }
        if ($t12Ok -or $t13Ok) {
            if ($t12Blocked -or $t13Blocked) { return @{ Verdict = "THROTTLED"; Color = "Yellow" } }
            return @{ Verdict = "AVAILABLE"; Color = "Green" }
        }
        if ($Cell12 -eq "RST" -or $Cell13 -eq "RST") { return @{ Verdict = "DPI RESET"; Color = "Red" } }
        if ($Cell12 -eq "DRP" -or $Cell13 -eq "DRP") { return @{ Verdict = "DPI BLOCK"; Color = "Red" } }
        return @{ Verdict = "IP BLOCK"; Color = "Red" }
    }

    function Invoke-Tls12HandshakeOnce {
        param([int]$TimeoutMs)
        $timedOut = $false
        $cell = "---"
        $rstPhase = $null
        $authStarted = $false
        $authCompleted = $false
        $conn = $null; $ssl = $null
        try {
            if ($ProxyConfig.Enabled) { $conn = Connect-ThroughProxy $Target 443 $ProxyConfig $TimeoutMs }
            else {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $ar = $tcp.BeginConnect($Result.IP, 443, $null, $null)
                if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "TcpTimeout" }
                $tcp.EndConnect($ar); $conn = @{ Tcp = $tcp; Stream = $tcp.GetStream() }
            }
            $ssl = [System.Net.Security.SslStream]::new($conn.Stream, $false)
            $enabled = [System.Security.Authentication.SslProtocols]::Tls12
            $authStarted = $true
            $auth = $ssl.BeginAuthenticateAsClient($Target, $null, $enabled, $false, $null, $null)
            if (-not $auth.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $timedOut = $true
                try { $ssl.Close() } catch {}
                throw "TLS12_TIMEOUT"
            }
            $ssl.EndAuthenticateAsClient($auth)
            $authCompleted = $true
            $cell = if ($ssl.IsAuthenticated) { "OK" } else { "DRP" }
        } catch {
            if ($_.Exception.Message -eq "TLS12_TIMEOUT") {
                $cell = "DRP"
                $rstPhase = "DRP"
            } else {
                $m = $_.Exception.Message
                if ($_.Exception.InnerException) { $m += " | Inner: $($_.Exception.InnerException.Message)" }
                if ($m -match "reset|сброс|forcibly|closed|разорвано|failed") {
                    $cell = "RST"
                    if ($authCompleted) { $rstPhase = "RST_POST" } else { $rstPhase = "RST_CH" }
                }
                elseif ($m -match "certificate|сертификат|remote|success") { $cell = "OK" }
                else { $cell = "DRP"; $rstPhase = "DRP" }
            }
        } finally {
            if ($ssl) { try { $ssl.Close() } catch {} }
            if ($conn) { try { $conn.Tcp.Close() } catch {} }
        }
        return [PSCustomObject]@{ Cell = $cell; TimedOut = $timedOut; RstPhase = $rstPhase }
    }

    $Result = [PSCustomObject]@{ IP="FAILED"; HTTP="---"; T12="---"; T13="---"; Lat="---"; Verdict="UNKNOWN"; Color="White"; Target=$Target; Number=0; RstPhase12=$null; RstPhase13=$null }
    $TO = if ($ProxyConfig.Enabled) { $CONST.ProxyTimeout } else { $CONST.TimeoutMs }
    $httpCap = [int]$CONST.Scan.HttpDirectCapMs
    $HttpTimeoutFast = if ($ProxyConfig.Enabled) { $CONST.ProxyTimeout } else { [Math]::Min($TO, $httpCap) }
    $TlsTimeoutFast  = if ($ProxyConfig.Enabled) { [int]$CONST.Scan.TlsFastMsProxy } else { [int]$CONST.Scan.TlsFastMsDirect }
    $TlsTimeoutRetry = if ($ProxyConfig.Enabled) { [Math]::Max([int]$CONST.Scan.TlsRetryMsProxyFloor, $CONST.ProxyTimeout) } else { [int]$CONST.Scan.TlsRetryMsDirect }

    Write-DebugLog "--- НАЧАЛО ПРОВЕРКИ ---"

    function Invoke-TcpConnectWithFallback {
        param($TargetIp, $TargetPort, $TimeoutMs)
        $tcp = $null
        try {
            $ipAddress = [System.Net.IPAddress]::Parse($TargetIp)
            $tcp = New-Object System.Net.Sockets.TcpClient($ipAddress.AddressFamily)
            $async = $tcp.BeginConnect($ipAddress, $TargetPort, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "Timeout" }
            $tcp.EndConnect($async)
            return $tcp
        } catch {
            if ($_.Exception.Message -match "address family|None of the discovered") {
                # Если это IPv6, пытаемся получить IPv4
                if ($TargetIp -match ':') {
                    Write-DebugLog "Ошибка семейства адресов при использовании IPv6 ($TargetIp), пробуем получить IPv4 для $Target"
                    $v4Address = $null
                    try {
                        $ips = [System.Net.Dns]::GetHostAddresses($Target)
                        $v4 = $ips | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                        if ($v4) {
                            $v4Address = $v4.IPAddressToString
                            Write-DebugLog "Найден IPv4: $v4Address"
                            # Обновляем кэш
                            if ($DnsCacheLock.WaitOne(1000)) {
                                $DnsCache[$Target] = $v4Address
                                [void]$DnsCacheLock.ReleaseMutex()
                            }
                            # Повторяем попытку с IPv4
                            $ipAddressV4 = [System.Net.IPAddress]::Parse($v4Address)
                            $tcp = New-Object System.Net.Sockets.TcpClient($ipAddressV4.AddressFamily)
                            $async = $tcp.BeginConnect($ipAddressV4, $TargetPort, $null, $null)
                            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "Timeout after fallback" }
                            $tcp.EndConnect($async)
                            $Result.IP = $v4Address
                            return $tcp
                        } else {
                            Write-DebugLog "Не удалось найти IPv4 для $Target"
                        }
                    } catch {
                        Write-DebugLog "Ошибка резолвинга IPv4 для $Target : $_"
                    }
                }
            }
            throw $_
        }
    }

    # 1. DNS
    $ipStr = $null
    if (-not $ProxyConfig.Enabled) {
        try {
            if ($DnsCacheLock.WaitOne(1000)) {
                if ($DnsCache.ContainsKey($Target)) { $ipStr = $DnsCache[$Target] }
                [void]$DnsCacheLock.ReleaseMutex()
            }
            if (-not $ipStr) {
                $ips = [System.Net.Dns]::GetHostAddresses($Target)
                $v4 = $ips | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                $v6 = $ips | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } | Select-Object -First 1

                # ЛОГИКА ВЫБОРА:
                if ($IpPreference -eq "IPv6" -and $v6 -and $NetInfo.HasIPv6) {
                    $ipStr = $v6.IPAddressToString
                } else {
                    $ipStr = if ($v4) { $v4.IPAddressToString } else { $v6.IPAddressToString }
                }

                if ($DnsCacheLock.WaitOne(1000)) {
                    $DnsCache[$Target] = $ipStr
                    [void]$DnsCacheLock.ReleaseMutex()
                }
            }
        } catch { $ipStr = "DNS_ERR" }
        $Result.IP = $ipStr
    } else { $Result.IP = "[ PROXIED ]" }

    # 2. HTTP Проверка
    Write-DebugLog "HTTP: Тест порта 80..."
    $conn = $null
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($ProxyConfig.Enabled) {
            $conn = Connect-ThroughProxy $Target 80 $ProxyConfig $TO
        } else {
            # Используем новую функцию с fallback на IPv4
            $tcp = Invoke-TcpConnectWithFallback -TargetIp $Result.IP -TargetPort 80 -TimeoutMs $HttpTimeoutFast
            $conn = @{ Tcp = $tcp; Stream = $tcp.GetStream() }
        }
        $Result.Lat = "$($sw.ElapsedMilliseconds)"
        $Result.HTTP = "OK"
        Write-DebugLog "HTTP: OK (Ping: $($Result.Lat))"
    } catch {
        $Result.HTTP = "ERR"
        Write-DebugLog "HTTP: Ошибка -> $($_.Exception.Message)" "WARN"
    } finally { if ($conn) { $conn.Tcp.Close() } }

    if ($Result.HTTP -eq "ERR") {
    $Result.T12 = "---"
    $Result.T13 = "---"
    $Result.Verdict = "IP BLOCK"
    $Result.Color = "Red"
    return $Result # Сразу выходим, не тратя время на TLS
}

    $tlsModeRaw = if ($TlsMode) { [string]$TlsMode } else { "Auto" }
    $consider13 = ($tlsModeRaw -notmatch '^(?i)TLS12$')
    $consider12 = ($tlsModeRaw -notmatch '^(?i)TLS13$')

    # 3. TLS Проверки
    $pHost = if ($ProxyConfig.Enabled) { $ProxyConfig.Host } else { "" }
    $pPort = if ($ProxyConfig.Enabled) { [int]$ProxyConfig.Port } else { 0 }

    $parallelTlsHandled = $false
    $t12TimedOut = $false

    if ($consider13 -and $consider12 -and $ParallelTlsFirstPass) {
        try {
            $t13task = [System.Threading.Tasks.Task]::Run({
                [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutFast)
            })
            $t12task = [System.Threading.Tasks.Task]::Run({
                Invoke-Tls12HandshakeOnce -TimeoutMs $TlsTimeoutFast
            })
            [System.Threading.Tasks.Task]::WaitAll(@($t13task, $t12task))
            $parallelOk = (-not $t13task.IsFaulted) -and (-not $t12task.IsFaulted)
            $tr = $null
            $hr = $null
            if ($parallelOk) {
                try { $tr = $t13task.Result } catch { $parallelOk = $false }
                try { $hr = $t12task.Result } catch { $parallelOk = $false }
            }
            if ($parallelOk -and ($null -ne $tr) -and ($null -ne $hr)) {
                $Result.T13 = [string]$tr
                if ($Result.T13 -eq "RST") { $Result.RstPhase13 = "RST_CH" }
                $Result.T12 = [string]$hr.Cell
                if ($hr.RstPhase) { $Result.RstPhase12 = $hr.RstPhase }
                elseif ($Result.T12 -eq "RST") { $Result.RstPhase12 = "RST_CH" }
                $t12TimedOut = [bool]$hr.TimedOut
                $parallelTlsHandled = $true
                Write-DebugLog "TLS: параллельный первый проход T13/T12 завершён" "INFO"
                if ($Result.T13 -eq "DRP") {
                    Write-DebugLog "TLS T13: повтор с увеличенным таймаутом ($TlsTimeoutRetry ms)" "INFO"
                    $retryT13 = [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutRetry)
                    if ($retryT13 -eq "OK" -or $retryT13 -eq "RST") {
                        $Result.T13 = $retryT13
                        if ($retryT13 -eq "RST") { $Result.RstPhase13 = "RST_CH" }
                    }
                }
            } else {
                Write-DebugLog "TLS: параллельный первый проход не удался, переход на последовательный путь" "WARN"
            }
        } catch {
            Write-DebugLog "TLS: ошибка параллельного первого прохода: $($_.Exception.Message)" "WARN"
        }
    }

    if (-not $parallelTlsHandled) {
        if ($consider13) {
            $Result.T13 = [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutFast)
            Write-DebugLog "TLS T13 : [RAW] Host=$Target Result=$($Result.T13)"
            if ($Result.T13 -eq "RST") { $Result.RstPhase13 = "RST_CH" }
            if ($Result.T13 -eq "DRP") {
                Write-DebugLog "TLS T13: повтор с увеличенным таймаутом ($TlsTimeoutRetry ms)" "INFO"
                $retryT13 = [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutRetry)
                if ($retryT13 -eq "OK" -or $retryT13 -eq "RST") {
                    $Result.T13 = $retryT13
                    if ($retryT13 -eq "RST") { $Result.RstPhase13 = "RST_CH" }
                }
            }
        } else {
            $Result.T13 = "N/A"
            Write-DebugLog "TLS T13: пропущено (режим TLS12)"
        }

        if ($consider12) {
            $hFirst = Invoke-Tls12HandshakeOnce -TimeoutMs $TlsTimeoutFast
            $Result.T12 = $hFirst.Cell
            if ($hFirst.RstPhase) { $Result.RstPhase12 = $hFirst.RstPhase }
            elseif ($Result.T12 -eq "RST") { $Result.RstPhase12 = "RST_CH" }
            $t12TimedOut = $hFirst.TimedOut
        } else {
            $Result.T12 = "N/A"
            Write-DebugLog "TLS T12: пропущено (режим TLS13)"
        }
    }

    # Retry при timeout T12: в Auto — только если T13 OK; в режиме только TLS12 — всегда при timeout
    $doT12Retry = $t12TimedOut -and $consider12 -and (($consider13 -and $Result.T13 -eq "OK") -or (-not $consider13))
    if ($doT12Retry) {
        Write-DebugLog "TLS T12: retry после timeout ($TlsTimeoutRetry ms)" "INFO"
        $hRetry = Invoke-Tls12HandshakeOnce -TimeoutMs $TlsTimeoutRetry
        $Result.T12 = $hRetry.Cell
        if ($hRetry.RstPhase) { $Result.RstPhase12 = $hRetry.RstPhase }
        elseif ($Result.T12 -eq "RST") { $Result.RstPhase12 = "RST_CH" }
    }

    $auxVerdictT13 = $null
    $auxVerdictT12 = $null
    if (-not $consider13) {
        if ($Result.T12 -eq "DRP" -or $Result.T12 -eq "RST") {
            $auxVerdictT13 = [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutFast)
            if ($auxVerdictT13 -eq "DRP") {
                $retryAux = [TlsScanner]::TestT13($Result.IP, $Target, $pHost, $pPort, $ProxyConfig.User, $ProxyConfig.Pass, $TlsTimeoutRetry)
                if ($retryAux -eq "OK" -or $retryAux -eq "RST") { $auxVerdictT13 = $retryAux }
            }
        }
    }
    if (-not $consider12) {
        if ($Result.T13 -eq "DRP" -or $Result.T13 -eq "RST") {
            $hx = Invoke-Tls12HandshakeOnce -TimeoutMs $TlsTimeoutFast
            $auxVerdictT12 = $hx.Cell
            if ($hx.TimedOut) {
                $hx2 = Invoke-Tls12HandshakeOnce -TimeoutMs $TlsTimeoutRetry
                $auxVerdictT12 = $hx2.Cell
            }
        }
    }

    # 4. Логика вердикта (с учётом TlsMode: только 1.2 / только 1.3 / оба)
    if (-not $consider13) {
        if ($null -ne $auxVerdictT13) {
            $auxPh13 = if ($auxVerdictT13 -eq "RST") { "RST_CH" } else { $null }
            $vd = Set-Verdict-DualTlsCells -Cell12 $Result.T12 -Cell13 $auxVerdictT13 -RstPhase12 $Result.RstPhase12 -RstPhase13 $auxPh13
            $Result.Verdict = $vd.Verdict
            $Result.Color = $vd.Color
        } else {
            if ($Result.RstPhase12 -eq "RST_CH" -or $Result.T12 -eq "RST") { $Result.Verdict = "DPI RESET"; $Result.Color = "Red" }
            elseif ($Result.T12 -eq "OK") { $Result.Verdict = "AVAILABLE"; $Result.Color = "Green" }
            elseif ($Result.T12 -eq "DRP") { $Result.Verdict = "DPI BLOCK"; $Result.Color = "Red" }
            else { $Result.Verdict = "IP BLOCK"; $Result.Color = "Red" }
        }
        return $Result
    }
    if (-not $consider12) {
        if ($null -ne $auxVerdictT12) {
            $auxPh12 = if ($auxVerdictT12 -eq "RST") { "RST_CH" } else { $null }
            $vd = Set-Verdict-DualTlsCells -Cell12 $auxVerdictT12 -Cell13 $Result.T13 -RstPhase12 $auxPh12 -RstPhase13 $Result.RstPhase13
            $Result.Verdict = $vd.Verdict
            $Result.Color = $vd.Color
        } else {
            if ($Result.RstPhase13 -eq "RST_CH" -or $Result.T13 -eq "RST") { $Result.Verdict = "DPI RESET"; $Result.Color = "Red" }
            elseif ($Result.T13 -eq "OK") { $Result.Verdict = "AVAILABLE"; $Result.Color = "Green" }
            elseif ($Result.T13 -eq "DRP") { $Result.Verdict = "DPI BLOCK"; $Result.Color = "Red" }
            else { $Result.Verdict = "IP BLOCK"; $Result.Color = "Red" }
        }
        return $Result
    }

    $vdAuto = Set-Verdict-DualTlsCells -Cell12 $Result.T12 -Cell13 $Result.T13 -RstPhase12 $Result.RstPhase12 -RstPhase13 $Result.RstPhase13
    $Result.Verdict = $vdAuto.Verdict
    $Result.Color = $vdAuto.Color
    return $Result
}

function Test-ScanRowVisualChanged {
    param($OldRow, $NewRow)
    if ($null -eq $OldRow -or $null -eq $NewRow) { return $true }
    # Latency changes on almost every run; compare stable status fields so repeat scans only repaint meaningful changes.
    $a = "$($OldRow.Number)|$($OldRow.Target)|$($OldRow.IP)|$($OldRow.HTTP)|$($OldRow.T12)|$($OldRow.T13)|$($OldRow.Verdict)|$($OldRow.Color)"
    $b = "$($NewRow.Number)|$($NewRow.Target)|$($NewRow.IP)|$($NewRow.HTTP)|$($NewRow.T12)|$($NewRow.T13)|$($NewRow.Verdict)|$($NewRow.Color)"
    return $a -ne $b
}

# ====================================================================================
# АСИНХРОННОЕ СКАНИРОВАНИЕ
# ====================================================================================
function Close-ScanRunspacePool {
    if ($null -eq $script:ScanRunspacePool) {
        $script:ScanRunspacePoolMax = 0
        return
    }
    try { $script:ScanRunspacePool.Close() } catch { }
    try { $script:ScanRunspacePool.Dispose() } catch { }
    $script:ScanRunspacePool = $null
    $script:ScanRunspacePoolMax = 0
}

function Ensure-ScanRunspacePool {
    param([Parameter(Mandatory)][int]$MaxThreads)
    if ($MaxThreads -lt 1) { $MaxThreads = 1 }
    $needNew = $script:ScanRunspacePoolForceRecreate -or
        ($null -eq $script:ScanRunspacePool) -or
        ($script:ScanRunspacePoolMax -ne $MaxThreads)
    if (-not $needNew) {
        try {
            if ($script:ScanRunspacePool.RunspacePoolStateInfo.State -ne [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
                $needNew = $true
            }
        } catch {
            $needNew = $true
        }
    }
    if ($needNew) {
        Close-ScanRunspacePool
        $script:ScanRunspacePoolForceRecreate = $false
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
        $pool.Open()
        $script:ScanRunspacePool = $pool
        $script:ScanRunspacePoolMax = $MaxThreads
        Write-DebugLog "Scan RunspacePool created (max=$MaxThreads)" "INFO"
    } else {
        Write-DebugLog "Scan RunspacePool reused (max=$MaxThreads)" "DEBUG"
    }
    return $script:ScanRunspacePool
}

function Complete-ScanCollectJob {
    param($Job, $Results)
    if ($Job.DoneInBg) { return $false }
    if (-not $Job.Handle.IsCompleted) { return $false }
    try {
        $raw = $Job.PowerShell.EndInvoke($Job.Handle)
        $res = if ($raw.PSObject -and $raw.Count -gt 1) { $raw[0] } else { $raw }
        $res | Add-Member -MemberType NoteProperty -Name "Number" -Value $Job.Number -Force
        $Job.Result = $res
        $Results[$Job.Index] = $res
        $Job.DoneInBg = $true
    } catch {
        $fail = [PSCustomObject]@{
            Target = $Job.Target; Number = $Job.Number; IP = "ERR"; HTTP = "---"
            T12 = "---"; T13 = "---"; Lat = "---"; Verdict = "TIMEOUT"; Color = "Red"
        }
        $Job.Result = $fail
        $Results[$Job.Index] = $fail
        $Job.DoneInBg = $true
    }
    return $true
}

function Start-ScanWithAnimation($Targets, $ProxyConfig, [bool]$PlaceholderRowsVisible = $false) {
    Write-DebugLog "Start-ScanWithAnimation: сбор результатов + водопад (полный / по изменившимся строкам)"
    # Снимок предыдущего скана до перезаписи LastScanResults в вызывающем коде
    $prevSnap = $null
    if ($script:LastScanResults -and $script:LastScanResults.Count -eq $Targets.Count) {
        $prevSnap = @($script:LastScanResults)
    }
    $useFullWaterfall = (-not $script:HasCompletedScan) -or ($null -eq $prevSnap)

    Sync-DynamicColPosFromLayout

    $cpuCount = [Environment]::ProcessorCount
    $poolMin = [int]$CONST.ScanPoolMinWorkers
    $poolDirectMax = [int]$CONST.ScanPoolDirectMax
    $poolProxyMax = [int]$CONST.ScanPoolProxyMax
    $poolCpuMul = [int]$CONST.ScanPoolCpuMultiplier
    $recommendedThreads = [Math]::Max($poolMin, [Math]::Min($poolDirectMax, $cpuCount * $poolCpuMul))
    if ($ProxyConfig.Enabled) {
        $recommendedThreads = [Math]::Min($recommendedThreads, $poolProxyMax)
    }
    $maxThreads = [Math]::Min($Targets.Count, $recommendedThreads)
    Write-DebugLog "Запуск пула потоков: $maxThreads воркеров (CPU=$cpuCount, proxy=$($ProxyConfig.Enabled))."

    $pool = Ensure-ScanRunspacePool -MaxThreads $maxThreads
    $jobs = [System.Collections.Generic.List[object]]::new()
    $results = New-Object 'object[]' $Targets.Count
    $completedTasks = 0

    for ($i=0; $i -lt $Targets.Count; $i++) {
        $ps = [PowerShell]::Create().AddScript($Worker).
            AddArgument($Targets[$i]).            # 1. $Target
            AddArgument($ProxyConfig).           # 2. $ProxyConfig
            AddArgument($CONST).                 # 3. $CONST
            AddArgument($DebugLogFile).          # 4. $DebugLogFile
            AddArgument([bool](Test-DebugLogEnabled)). # 5. effective debug (env или конфиг)
            AddArgument($script:DnsCache).       # 6. $DnsCache
            AddArgument($script:DnsCacheLock).   # 7. $DnsCacheLock
            AddArgument($script:NetInfo).        # 8. $NetInfo
            AddArgument($script:Config.IpPreference). # 9. $IpPreference
            AddArgument([string]$script:Config.TlsMode). # 10. $TlsMode
            AddArgument([string]$script:DebugLogMutexName). # 11. mutex для записи в общий лог
            AddArgument([bool]($script:Config.ScanParallelTlsFirstPass -eq $true)) # 12. параллельный первый проход TLS

        $ps.RunspacePool = $pool
        [void]$jobs.Add([PSCustomObject]@{
            PowerShell = $ps; Handle = $ps.BeginInvoke(); Index = $i; Number = $i + 1
            Target = $Targets[$i]; DoneInBg = $false; Result = $null; Revealed = $false
        })
    }

    # Первый скан рисует пустые строки только в видимом viewport. Повторный скан оставляет прошлые результаты.
    Sync-DynamicColPosFromLayout
    $vpInit = Get-TableViewportIndexRange -TargetCount $Targets.Count
    if ($useFullWaterfall -and -not $PlaceholderRowsVisible) {
        for ($pi = [int]$vpInit.StartIdx; $pi -le [int]$vpInit.EndIdx; $pi++) {
            $jb = $jobs[$pi]
            $ph = New-PlaceholderResultRow -Number $jb.Number -Target $jb.Target
            $screenRow = [int]$vpInit.Layout.TableBodyStart + ($pi - [int]$vpInit.StartIdx)
            Write-ResultLine -row $screenRow -result $ph
        }
        Update-TableBottomScrollRule -Layout $vpInit.Layout
    }
    try {
        $script:ScanLayoutSnapW = [Console]::WindowWidth
        $script:ScanLayoutSnapH = [Console]::WindowHeight
    } catch {
        $script:ScanLayoutSnapW = $null
        $script:ScanLayoutSnapH = $null
    }
    $script:ResizePendingSince = $null

    $aborted = $false
    $frameCounter = 0
    $animTargetMs = 1000.0 / [double]($CONST.AnimFps)
    $frameSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Троттлинг статус-бара: полная строка не каждый кадр (~30 FPS), чтобы не «дребезжало»
    $scanBarLastMs = [Environment]::TickCount64
    $scanBarLastDone = -9999
    $scanBarLastBucket = -9999
    $uiThrottleCollect = if ($CONST.UiScan -and $null -ne $CONST.UiScan.StatusBarThrottleCollectMs) { [int]$CONST.UiScan.StatusBarThrottleCollectMs } else { 240 }

    # --- ЭТАП 1 ---
    while (-not $aborted) {
        $frameCounter++

        $tcScan = [Math]::Max(1, $Targets.Count)
        $pctScan = $completedTasks / [double]$tcScan
        $resizedScan = Test-ScanPhaseConsoleLayoutChanged
        $nowBar = [Environment]::TickCount64
        # 10% progress buckets (was *40 = ~2.5%) — fewer status writes
        $bucketScan = [int]($pctScan * 10)
        if ($resizedScan -or ($completedTasks -ne $scanBarLastDone) -or (($nowBar - $scanBarLastMs) -ge $uiThrottleCollect) -or ($bucketScan -ne $scanBarLastBucket)) {
            $scanBarLastMs = $nowBar
            $scanBarLastDone = $completedTasks
            $scanBarLastBucket = $bucketScan
            Invoke-ScanRedrawIfConsoleResized -LiveResults $results -Targets $Targets -StatusBarMessage "[ SCAN ] Сбор: $completedTasks / $tcScan" -Progress $pctScan
        }

        if ([Console]::KeyAvailable) {
            $sk = [Console]::ReadKey($true).Key
            if ($sk -in @("Q", "Escape")) {
                [Console]::CursorVisible = $false
                try { [Console]::CursorSize = 1 } catch { }
                $aborted = $true; break
            }
            elseif (Invoke-CoalescedTableScroll -FirstKey $sk -Results $results) {
                # viewport already painted once after key coalesce
            }
        }

        foreach ($j in $jobs) {
            if (Complete-ScanCollectJob -Job $j -Results $results) { $completedTasks++ }
        }

        if ($completedTasks -ge $Targets.Count) { break }

        $waitMs = [int][math]::Floor($animTargetMs - $frameSw.Elapsed.TotalMilliseconds)
        if ($waitMs -lt 0) { $waitMs = 0 }
        $pendingHandles = New-Object System.Collections.Generic.List[System.Threading.WaitHandle]
        foreach ($j in $jobs) {
            if (-not $j.DoneInBg -and $j.Handle) {
                try { [void]$pendingHandles.Add($j.Handle.AsyncWaitHandle) } catch { }
            }
        }
        if ($pendingHandles.Count -eq 1) {
            [void]$pendingHandles[0].WaitOne($waitMs)
        } elseif ($pendingHandles.Count -gt 1) {
            $arr = $pendingHandles.ToArray()
            if ($arr.Length -gt 63) {
                $chunk = New-Object System.Threading.WaitHandle[] 63
                [Array]::Copy($arr, $chunk, 63)
                [void][System.Threading.WaitHandle]::WaitAny($chunk, $waitMs)
            } else {
                [void][System.Threading.WaitHandle]::WaitAny($arr, $waitMs)
            }
        } elseif ($waitMs -gt 0) {
            [System.Threading.Thread]::Sleep($waitMs)
        }
        $frameSw.Restart()
    }

    # Stop incomplete workers on abort so runspaces return to the shared pool.
    if ($aborted) {
        foreach ($j in $jobs) {
            if (-not $j.DoneInBg) {
                try { $j.PowerShell.Stop() } catch { $script:ScanRunspacePoolForceRecreate = $true }
                try {
                    if ($j.Handle) { $null = $j.PowerShell.EndInvoke($j.Handle) }
                } catch { }
                $j.DoneInBg = $true
            }
        }
    }
    foreach ($j in $jobs) { try { $j.PowerShell.Dispose() } catch {} }

    $commitResults = $true
    $returnResults = $results

    # --- Abort: never commit null/IDLE holes over a good prior scan ---
    if ($aborted) {
        if ($script:HasCompletedScan -and $prevSnap) {
            Write-DebugLog "Scan aborted — keeping previous LastScanResults" "INFO"
            $commitResults = $false
            $returnResults = $prevSnap
            # Repaint visible viewport so screen matches committed data
            $vpAbort = Get-TableViewportIndexRange -TargetCount $prevSnap.Count
            for ($ai = [int]$vpAbort.StartIdx; $ai -le [int]$vpAbort.EndIdx; $ai++) {
                if ($prevSnap[$ai]) {
                    $screenRow = [int]$vpAbort.Layout.TableBodyStart + ($ai - [int]$vpAbort.StartIdx)
                    Write-ResultLine -row $screenRow -result $prevSnap[$ai]
                }
            }
            Update-TableBottomScrollRule -Layout $vpAbort.Layout
        } else {
            Write-DebugLog "Scan aborted — filling unfinished rows as SCAN ABORTED" "INFO"
            for ($ai = 0; $ai -lt $Targets.Count; $ai++) {
                if ($null -eq $results[$ai]) {
                    $results[$ai] = New-AbortedResultRow -Number ($ai + 1) -Target $Targets[$ai]
                }
            }
            $vpAbort = Get-TableViewportIndexRange -TargetCount $Targets.Count
            for ($ai = [int]$vpAbort.StartIdx; $ai -le [int]$vpAbort.EndIdx; $ai++) {
                $screenRow = [int]$vpAbort.Layout.TableBodyStart + ($ai - [int]$vpAbort.StartIdx)
                Write-ResultLine -row $screenRow -result $results[$ai]
            }
            Update-TableBottomScrollRule -Layout $vpAbort.Layout
            $returnResults = $results
            $commitResults = $true
        }
        Draw-StatusBar -Message "[ ABORTED ] Скан прерван" -Fg "Black" -Bg "Red"
    }

    # --- ЭТАП 2: «водопад» — первый успешный проход полностью; дальше только задержка на изменившихся строках ---
    if (-not $aborted) {
        $totalCount = $Targets.Count
        $frameCounter = 0
        $revealFps = [double]$CONST.AnimFps
        if ($CONST.UiScan -and ($null -ne $CONST.UiScan.RevealAnimFps)) {
            try {
                $ri = [int]$CONST.UiScan.RevealAnimFps
                if ($ri -gt 0) { $revealFps = [double]$ri }
            } catch { }
        }
        $animTargetMs = 1000.0 / $revealFps
        $frameSw.Restart()
        $revealBarLastMs = [Environment]::TickCount64
        $revealBarLastBucket = -9999
        $uiThrottleReveal = if ($CONST.UiScan -and $null -ne $CONST.UiScan.StatusBarThrottleRevealMs) { [int]$CONST.UiScan.StatusBarThrottleRevealMs } else { 280 }
        # Scale LAT bars before first Write-ResultLine (default LatBarMaxMs=1 made every bar solid).
        try { Update-LatBarScale -Results $results } catch { }

        for ($i = 0; $i -lt $totalCount; $i++) {
            $frameCounter++

            $pctReveal = ($i + 1) / [double][Math]::Max(1, $totalCount)
            $resizedReveal = Test-ScanPhaseConsoleLayoutChanged
            $nowRv = [Environment]::TickCount64
            $bucketRv = [int]($pctReveal * 10)
            if ($resizedReveal -or (($nowRv - $revealBarLastMs) -ge $uiThrottleReveal) -or ($bucketRv -ne $revealBarLastBucket)) {
                $revealBarLastMs = $nowRv
                $revealBarLastBucket = $bucketRv
                Invoke-ScanRedrawIfConsoleResized -LiveResults $results -Targets $Targets -StatusBarMessage "[ SCAN ] Раскрытие: $($i+1) / $totalCount" -Progress $pctReveal
            }

            $j = $jobs[$i]
            $res = $results[$i]

            if ($null -eq $res) {
                $res = [PSCustomObject]@{
                    Target=$j.Target; Number=$j.Number; IP="ERR"; HTTP="---";
                    T12="---"; T13="---"; Lat="---"; Verdict="TIMEOUT"; Color="Red"
                }
                $results[$i] = $res
            }

            $rowChanged = $true
            if (-not $useFullWaterfall -and $prevSnap -and $i -lt $prevSnap.Count) {
                $rowChanged = Test-ScanRowVisualChanged -OldRow $prevSnap[$i] -NewRow $res
            }

            $screenRow = Get-TableScreenRow -TargetIndex $i -TargetCount $totalCount
            if ($screenRow -ge 0) {
                if ($useFullWaterfall -or $rowChanged) {
                    Write-ResultLine -row $screenRow -result $res
                    $sleepMs = $animTargetMs - $frameSw.Elapsed.TotalMilliseconds
                    if ($sleepMs -gt 0.5) { [System.Threading.Thread]::Sleep([int][math]::Floor($sleepMs)) }
                }
                else {
                    Write-ResultLatency -row $screenRow -result $res
                }
                $frameSw.Restart()
            }

            if ([Console]::KeyAvailable) {
                $rk = [Console]::ReadKey($true).Key
                if ($rk -in @("Q", "Escape")) { break }
                elseif (Invoke-CoalescedTableScroll -FirstKey $rk -Results $results) {
                    # viewport already painted once after key coalesce
                }
            }
        }

        $script:HasCompletedScan = $true
        $returnResults = $results
        $commitResults = $true
        Draw-StatusBar
    }

    # Обновляем NetInfo только при необходимости (skip on abort to return to Idle faster)
    if (-not $aborted) {
    $currentISP = $script:NetInfo.ISP
    $currentLOC = $script:NetInfo.LOC
    $cacheAge = (Get-Date).Ticks - $script:NetInfo.TimestampTicks
    $ageMinutes = [TimeSpan]::FromTicks($cacheAge).TotalMinutes

    $needUpdate = $false
    if ($ageMinutes -gt 30) {
        Write-DebugLog "NetInfo устарел (${ageMinutes} мин), обновляем"
        $needUpdate = $true
    }
    if ($currentISP -eq "Loading..." -or $currentISP -eq "Detecting..." -or $currentISP -eq "Unknown") {
        Write-DebugLog "ISP не определён, обновляем"
        $needUpdate = $true
    }
    if ($currentISP -eq "Background update" -or $currentLOC -eq "Next scan") {
        Write-DebugLog "ISP временный (фон), обновляем"
        $needUpdate = $true
    }

    if ($needUpdate) {
        Write-DebugLog "NetInfo needs refresh — starting background updater (non-blocking)" "INFO"
        Start-BackgroundNetInfoUpdate
    } else {
        Write-DebugLog "NetInfo актуален, пропускаем обновление (ISP=$currentISP, возраст=${ageMinutes} мин)"
    }

    # Ложный IPv6: только если скан завершён полностью и каждая строка — IP BLOCK или UNKNOWN
    $resolved = @($results | Where-Object { $_ })
    $nonIpBlock = @($resolved | Where-Object { $_.Verdict -ne "IP BLOCK" -and $_.Verdict -ne "UNKNOWN" })
    $allIpBlock = ($resolved.Count -gt 0) -and ($resolved.Count -eq $results.Count) -and ($nonIpBlock.Count -eq 0)
    if ($allIpBlock -and $script:NetInfo.HasIPv6 -eq $true) {
        Write-DebugLog "Все тесты дали IP BLOCK, но HasIPv6=true. Переключаем HasIPv6 в false." "WARN"
        $script:NetInfo.HasIPv6 = $false
        if ($script:Config.NetCache) { $script:Config.NetCache.HasIPv6 = $false }
        Save-Config $script:Config
        if ($script:DnsCacheLock.WaitOne(1000)) {
            $toRemove = @()
            foreach ($key in $script:DnsCache.Keys) {
                if ($script:DnsCache[$key] -match ':') { $toRemove += $key }
            }
            foreach ($key in $toRemove) { $script:DnsCache.Remove($key) }
            [void]$script:DnsCacheLock.ReleaseMutex()
        }
    }

    # Обновляем ширину IP колонки на основе реальных результатов
    if ($results) {
        $maxIp = ($results | ForEach-Object {
            if ($_ -and $_.IP -and $_.IP -ne "[ PROXIED ]") { $_.IP.Length } else { 16 }
        } | Measure-Object -Maximum).Maximum
        $script:IpColumnWidth = [Math]::Max($maxIp, 16)
    }
    } # end -not $aborted NetInfo block

    Sync-DynamicColPosFromLayout
    $script:ScanLayoutSnapW = $null
    $script:ScanLayoutSnapH = $null
    $script:ResizePendingSince = $null
    Update-UiConsoleSnapshot
    return [PSCustomObject]@{
        Results = $returnResults
        Aborted = $aborted
        CommitResults = $commitResults
    }
}

function Sync-DnsCacheFromConfig {
    $script:DnsCache = [hashtable]::Synchronized(@{})
    if ($script:Config.DnsCache -and $script:Config.DnsCache.PSObject) {
        foreach ($prop in $script:Config.DnsCache.PSObject.Properties) {
            if ($prop.MemberType -eq "NoteProperty") { $script:DnsCache[$prop.Name] = $prop.Value }
        }
    }
}

function Test-InternetAvailable {
    $internetAvailable = $false
    try {
        # Самый быстрый тест - ping до 8.8.8.8
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send("8.8.8.8", 1000)
        $internetAvailable = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        $ping.Dispose()
    } catch {
        # Если ping не работает, пробуем TCP
        try {
            $tcpTest = New-Object System.Net.Sockets.TcpClient
            $async = $tcpTest.BeginConnect("8.8.8.8", 53, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000)) {
                $tcpTest.EndConnect($async)
                $internetAvailable = $true
            }
            $tcpTest.Close()
        } catch { $internetAvailable = $false }
    }
    return $internetAvailable
}

function Start-QuickNetInfoUpdater {
    param([double]$AgeMinutes)

    Write-DebugLog "Кэш устарел ($([math]::Round($AgeMinutes,1)) мин), запускаем фоновое обновление" "INFO"

    # Запускаем обновление в фоне (не блокируем скан!) — отдельный процесс PS, чтобы не грузить процесс UI
    $existing = Get-Job -Name "NetInfoUpdater" -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-Job $existing -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $existing -Force -ErrorAction SilentlyContinue } catch {}
    }

    Start-Job -Name "NetInfoUpdater" -ScriptBlock {
        param($configDir, $debugLog, $userAgent, $mutexName, $mutexWaitMs)

        function Write-BgLog($msg) {
            $line = "[$(Get-Date -Format 'HH:mm:ss')] [BG] $msg`r`n"
            $mtx = $null
            $got = $false
            try {
                try { $mtx = if ($mutexName) { [System.Threading.Mutex]::OpenExisting($mutexName) } else { $null } } catch { $mtx = $null }
                if ($mtx) { try { $got = $mtx.WaitOne([int]$mutexWaitMs) } catch { $got = $false } }
                if ($got) {
                    [System.IO.File]::AppendAllText($debugLog, $line, [System.Text.Encoding]::UTF8)
                } else {
                    try { [System.IO.File]::AppendAllText($debugLog, $line, [System.Text.Encoding]::UTF8) } catch { }
                }
            } catch { }
            finally {
                if ($got -and $mtx) { try { [void]$mtx.ReleaseMutex() } catch { } }
                if ($mtx) { try { $mtx.Dispose() } catch { } }
            }
        }

        Write-BgLog "Фоновое обновление NetInfo начато"

        # Быстрое получение DNS
        $dns = "UNKNOWN"
        try {
            $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                Where-Object { $_.DNSServerSearchOrder -ne $null -and @($_.DNSServerSearchOrder).Count -gt 0 } |
                Select-Object -First 1
            if ($wmi) { $dns = [string](@($wmi.DNSServerSearchOrder)[0]) }
        } catch {}
        if ($dns -eq "UNKNOWN") {
            try {
                $row = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.ServerAddresses -and @($_.ServerAddresses).Count -gt 0 } |
                    Select-Object -First 1
                if ($row) { $dns = [string](@($row.ServerAddresses)[0]) }
            } catch {}
        }

        # 2. Локальный CDN через redirector (ИСПРАВЛЕННАЯ версия)
        $cdn = "manifest.googlevideo.com"  # fallback
        try {
            $rnd = [guid]::NewGuid().ToString().Substring(0,8)
            $redirectorUrl = "http://redirector.googlevideo.com/report_mapping?di=no&nocache=$rnd"

            Write-BgLog "Запрос локального CDN: $redirectorUrl"

            $req = [System.Net.WebRequest]::Create($redirectorUrl)
            $req.Timeout = 3000
            if ($userAgent) { $req.UserAgent = $userAgent }

            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $raw = $reader.ReadToEnd()
            $resp.Close()

            Write-BgLog "Ответ redirector: [$raw]"

            # НОВЫЙ, более надежный парсинг
            # Пример ответа: " => r1.freedom-voz3.googlevideo.com"
            # Или: "=> r1.freedom-voz3.googlevideo.com"
            # Или: "=> r1-123.googlevideo.com"

            $cdnShort = $null
            if ($raw -match '=>\s+([\w-]+)') {
                $cdnShort = $matches[1]
            }

            if ($cdnShort -and $cdnShort -ne 'r1') {
                # как в tools/cdn-tester.bat: => <short>  -> r1.<short>.googlevideo.com
                $cdn = "r1.$cdnShort.googlevideo.com"
                Write-BgLog "Найден локальный CDN (короткая форма): $cdn"
            }
            elseif ($raw -match '=>\s*([a-zA-Z0-9.\-]+\.googlevideo\.com)') {
                $cdn = $matches[1]
                Write-BgLog "Найден локальный CDN (full domain): $cdn"
            }
            else {
                Write-BgLog "Не удалось распарсить ответ, используем fallback: $cdn"
            }

        } catch {
            Write-BgLog "CDN определение не удалось: $($_.Exception.Message)"
            $cdn = "manifest.googlevideo.com"
        }

        # Финальная очистка - только чистое значение
        $cdn = $cdn.Trim()
        Write-BgLog "Финальный CDN: '$cdn'"

        # Дополнительная очистка - убираем пробелы и дубликаты
        $cdn = ($cdn -split '\s+')[0]  # Берем только первое слово, если вдруг их несколько

        # GEO из кэша (не обновляем, чтобы не тратить время)
        $isp = "Background update"
        $loc = "Next scan"

        # IPv6
        $hasV6 = $false
        try {
            $t = New-Object System.Net.Sockets.TcpClient([System.Net.Sockets.AddressFamily]::InterNetworkV6)
            $a = $t.BeginConnect("ipv6.google.com", 80, $null, $null)
            if ($a.AsyncWaitHandle.WaitOne(1000)) {
                $t.EndConnect($a)
                $hasV6 = $true
            }
            $t.Close()
        } catch {}

        $result = @{
            DNS = $dns
            CDN = $cdn
            ISP = $isp
            LOC = $loc
            TimestampTicks = (Get-Date).Ticks
            HasIPv6 = $hasV6
        }

        # Сохраняем в файл конфига
        $configFile = Join-Path $configDir "YT-DPI_config.json"
        if (Test-Path $configFile) {
            try {
                $config = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($config.NetCache) {
                    $config.NetCache.DNS = $result.DNS
                    $config.NetCache.CDN = $result.CDN
                    $config.NetCache.TimestampTicks = $result.TimestampTicks
                    $config.NetCache.HasIPv6 = $result.HasIPv6
                } else {
                    $config.NetCache = $result
                }
                $config | ConvertTo-Json -Depth 5 -Compress | Set-Content $configFile -Encoding UTF8 -Force
                Write-BgLog "NetInfo network fields updated in config"
            } catch { Write-BgLog "Ошибка сохранения: $_" }
        }

        Write-BgLog "Фоновое обновление завершено"
        return $result
    } -ArgumentList $script:ConfigDir, $DebugLogFile, $script:UserAgent, $script:DebugLogMutexName, [int]$CONST.Mutex.WaitMs | Out-Null
}

function Update-TargetsBeforeScan {
    # Используем кэш только если это не заглушка Loading/Unknown.
    if (Test-NetInfoUsable $script:Config.NetCache) {
        $script:NetInfo = $script:Config.NetCache
    }

    # Проверяем, не пора ли обновить кэш в фоне
    $cacheAge = (Get-Date).Ticks - $script:NetInfo.TimestampTicks
    $ageMinutes = [TimeSpan]::FromTicks($cacheAge).TotalMinutes

    if ($ageMinutes -gt 10 -or -not (Test-NetInfoUsable $script:NetInfo)) {
        Start-QuickNetInfoUpdater -AgeMinutes $ageMinutes
    } else {
        Write-DebugLog "Используем свежий кэш (возраст: $([math]::Round($ageMinutes,1)) мин)" "INFO"
    }

    # === БЫСТРОЕ ОБНОВЛЕНИЕ ТАРГЕТОВ ===
    $NewTargets = Get-Targets -NetInfo $script:NetInfo
    $oldTargetsKey = if ($script:Targets) { (@($script:Targets) -join "`n") } else { "" }
    $newTargetsKey = if ($NewTargets) { (@($NewTargets) -join "`n") } else { "" }
    $NeedClear = ($NewTargets.Count -ne $script:Targets.Count)
    $NeedTableRefresh = $NeedClear -or ($oldTargetsKey -ne $newTargetsKey)
    $script:Targets = $NewTargets
    if ($NeedTableRefresh) {
        $script:TableScrollOffset = 0
        $null = Clamp-TableScroll -TargetCount $script:Targets.Count
    }

    # Сохраняем предыдущие результаты на экране до старта сбора (строки «обнулятся» внутри Start-Scan)
    $rowsBeforeScan = if (-not $NeedTableRefresh -and $script:LastScanResults -and $script:LastScanResults.Count -eq $script:Targets.Count) {
        $script:LastScanResults
    } else { $null }

    return [PSCustomObject]@{ NeedClear = $NeedClear; NeedTableRefresh = $NeedTableRefresh; RowsBeforeScan = $rowsBeforeScan }
}

function Update-NetInfoFromCompletedJob {
    $bgJob = Get-Job -Name "NetInfoUpdater" -ErrorAction SilentlyContinue
    if ($bgJob -and $bgJob.State -eq "Completed") {
        $newNetInfo = Receive-Job $bgJob
        Remove-Job $bgJob
        $script:NetInfoUpdating = $false
        if ($newNetInfo -and (Test-NetInfoUsable $newNetInfo)) {
            Write-DebugLog "NetInfo обновлен в фоне, обновляем UI" "INFO"
            $null = Set-NetInfoCacheIfUsable $newNetInfo
            $oldTargetsKey = if ($script:Targets) { (@($script:Targets) -join "`n") } else { "" }
            $script:NetInfo = $newNetInfo
            $script:Targets = Get-Targets -NetInfo $script:NetInfo
            $newTargetsKey = if ($script:Targets) { (@($script:Targets) -join "`n") } else { "" }
            Save-Config $script:Config
            if (-not $script:HasCompletedScan) {
                if ($oldTargetsKey -ne $newTargetsKey) {
                    Draw-UI $script:NetInfo $script:Targets $null $false
                } else {
                    Update-NetInfoPanel $script:NetInfo
                }
                Draw-StatusBar
                return
            }
            Update-NetInfoPanel $script:NetInfo
        }
    }
}

function Save-ScanReport {
    Write-DebugLog "Сохранение отчёта"
    if (-not $script:BatchMode) {
        Draw-StatusBar -Message "[ WAIT ] SAVING RESULTS TO FILE..." -Fg "Black" -Bg "Cyan"
    }
    $logPath = if ($script:TxtReportPath) { $script:TxtReportPath } else { Join-Path -Path (Get-Location).Path -ChildPath "YT-DPI_Report.txt" }
    if (Get-Command Save-ScanReportToPath -ErrorAction SilentlyContinue) {
        $null = Save-ScanReportToPath -Path $logPath
    } else {
        # fallback minimal
        Draw-StatusBar -Message "[ ERROR ] Save-ScanReportToPath missing" -Fg "White" -Bg "Red"
        return
    }
    $jsonPath = $script:JsonReportPath
    if (-not $jsonPath) {
        $jsonPath = Join-Path (Split-Path -Parent $logPath) "YT-DPI_Report.json"
    }
    if (Get-Command Export-YtDpiJsonReport -ErrorAction SilentlyContinue) {
        Export-YtDpiJsonReport -Path $jsonPath
    }
    if (-not $script:BatchMode) {
        Start-Sleep -Seconds 2
        Draw-StatusBar
        Clear-KeyBuffer
    }
}

function Get-MainTableResults {
    if ($script:LastScanResults -and $script:Targets -and $script:LastScanResults.Count -eq $script:Targets.Count) {
        return $script:LastScanResults
    }
    return $null
}

function Invoke-DnsScanAction {
    Write-DebugLog "DNS scan mode [D]"
    $row = Get-FeedbackRow -count $script:Targets.Count
    Write-StatusLine -Row $row -Message "" -Fg "White" -Bg "Black"
    if (-not (Get-Command Invoke-DnsCompareProbe -ErrorAction SilentlyContinue)) {
        Write-StatusLine -Row $row -Message "[ DNS ] DNS probe unavailable" -Fg "White" -Bg "DarkRed"
        Start-Sleep -Seconds 2
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }
    Write-StatusLine -Row $row -Message "[ DNS ] System resolve vs DoH (Cloudflare/Google)..." -Fg "White" -Bg "DarkCyan"
    $rows = $null
    try {
        $rows = @(Invoke-DnsCompareProbe)
    } catch {
        Write-DebugLog "Invoke-DnsScanAction: $_" "ERROR"
        Write-StatusLine -Row $row -Message ("[ DNS ] Error: {0}" -f $_.Exception.Message) -Fg "White" -Bg "DarkRed"
        Start-Sleep -Seconds 3
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }
    $bad = @($rows | Where-Object { $_.Status -ne "OK" })
    $bg = if ($bad.Count -gt 0) { "DarkYellow" } else { "DarkGreen" }
    $summary = if ($bad.Count -gt 0) {
        ($bad | ForEach-Object { "{0}={1}" -f $_.Host, $_.Status }) -join "; "
    } else {
        ("all OK ({0} hosts)" -f $rows.Count)
    }
    if ($summary.Length -gt 90) { $summary = $summary.Substring(0, 87) + "..." }
    $resultMsg = "[ DNS ] $summary  [ENTER/ESC]"
    Write-StatusLine -Row $row -Message $resultMsg -Fg "White" -Bg $bg
    Write-DebugLog ("DNS scan: {0}" -f (($rows | ForEach-Object { "{0}:{1}" -f $_.Host, $_.Status }) -join ", "))
    while ($true) {
        if (Test-UiConsoleLayoutChanged) {
            $null = Invoke-FullUiRedrawIfConsoleResized
            $row = Get-FeedbackRow -count $script:Targets.Count
            Write-StatusLine -Row $row -Message $resultMsg -Fg "White" -Bg $bg
        }
        if ([Console]::KeyAvailable) {
            $dk = [Console]::ReadKey($true).Key
            if ($dk -in @("Enter", "Escape", "Spacebar", "D")) { break }
        }
        Start-Sleep -Milliseconds 50
    }
    Write-StatusLine -Row $row -Message "" -Fg "White" -Bg "Black"
    Draw-StatusBar
    Clear-KeyBuffer
}


# ====================================================================================
# YT-DPI 3.x EXTRA DIAGNOSTICS (inlined - single-file distribution)
# ====================================================================================

# ====================================================================================
# YT-DPI 3.0 - EXTRA DIAGNOSTICS (Windows)
# ====================================================================================

function Test-WarnBypassToolsEnabled {
    # Bypass tools are a normal way to verify results — never warn about them.
    return $false
}

function Invoke-BypassToolsSelfCheck {
    # Kept for smoke/JSON compatibility; no UI warnings.
    $script:ExtraDiag.BypassTools = @{ Detected = $false; Names = @() }
    return $script:ExtraDiag.BypassTools
}

function Show-BypassWarningBanner {
    return
}

function Complete-PostScanExtrasFinalize {
    $rstCh = 0; $rstPost = 0
    if ($script:LastScanResults) {
        foreach ($r in @($script:LastScanResults)) {
            if (-not $r) { continue }
            foreach ($ph in @($r.RstPhase12, $r.RstPhase13)) {
                if ($ph -eq "RST_CH") { $rstCh++ }
                elseif ($ph -eq "RST_POST") { $rstPost++ }
            }
        }
    }
    $script:ExtraDiag.RstStats = @{ RstCh = $rstCh; RstPost = $rstPost }
    Build-Recommendations -ScanRows $script:LastScanResults -Extra $script:ExtraDiag | Out-Null
    try { Update-LatBarScale -Results $script:LastScanResults } catch { }
}

function Invoke-PostScanExtrasBody {
    # Runs in extras runspace (or sync batch). Mutates $script:ExtraDiag; returns snapshot.
    try { Invoke-DnsCompareProbe | Out-Null } catch { Write-DebugLog "DNS probe: $_" "WARN" }
    try { Invoke-QuicUdpProbe | Out-Null } catch { Write-DebugLog "QUIC probe: $_" "WARN" }
    try { Invoke-Tcp16Probe | Out-Null } catch { Write-DebugLog "TCP16 probe: $_" "WARN" }
    try { Invoke-IpVsSniProbe | Out-Null } catch { Write-DebugLog "IpVsSni probe: $_" "WARN" }
    return [PSCustomObject]@{
        Dns    = $script:ExtraDiag.Dns
        Quic   = $script:ExtraDiag.Quic
        Tcp16  = $script:ExtraDiag.Tcp16
        IpVsSni = $script:ExtraDiag.IpVsSni
    }
}

function Stop-DeferredPostScanExtras {
    $ps = $script:ExtrasPs
    $handle = $script:ExtrasHandle
    $rs = $script:ExtrasRunspace
    $script:ExtrasPs = $null
    $script:ExtrasHandle = $null
    $script:ExtrasRunspace = $null
    $script:ExtrasPending = $false
    $script:ExtrasStep = 0
    if ($null -eq $ps) {
        if ($rs) { try { $rs.Close() } catch { }; try { $rs.Dispose() } catch { } }
        return
    }
    try {
        if ($handle -and -not $handle.IsCompleted) { $ps.Stop() }
    } catch { }
    try {
        if ($handle) { $null = $ps.EndInvoke($handle) }
    } catch { }
    try { $ps.Dispose() } catch { }
    if ($rs) {
        try { $rs.Close() } catch { }
        try { $rs.Dispose() } catch { }
    }
}

function Start-DeferredPostScanExtras {
    if ($script:NoExtras -or $script:BatchMode) {
        $script:ExtrasStep = 0
        $script:ExtrasPending = $false
        return
    }
    Stop-DeferredPostScanExtras
    $null = Ensure-TlsScannerLoaded

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $fnNames = @(
        'Write-DebugLog',
        'Test-DebugLogEnabled',
        'Invoke-DnsCompareProbe',
        'Invoke-QuicUdpProbe',
        'New-QuicInitialProbeBytes',
        'Invoke-Tcp16Probe',
        'Invoke-IpVsSniProbe',
        'Ensure-TlsScannerLoaded',
        'Test-TlsScannerReady',
        'Invoke-PostScanExtrasBody'
    )
    foreach ($n in $fnNames) {
        $cmd = Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue
        if ($cmd) {
            [void]$iss.Commands.Add(
                (New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($n, $cmd.Definition))
            )
        }
    }
    $varType = [System.Management.Automation.Runspaces.SessionStateVariableEntry]
    [void]$iss.Variables.Add((New-Object $varType('CONST', $CONST, $null)))
    [void]$iss.Variables.Add((New-Object $varType('DebugLogFile', $DebugLogFile, $null)))
    [void]$iss.Variables.Add((New-Object $varType('DEBUG_ENABLED', [bool]$DEBUG_ENABLED, $null)))
    [void]$iss.Variables.Add((New-Object $varType('DebugLogMutex', $DebugLogMutex, $null)))
    if (Get-Variable -Name tlsCode -Scope Script -ErrorAction SilentlyContinue) {
        [void]$iss.Variables.Add((New-Object $varType('tlsCode', $tlsCode, $null)))
    } elseif (Get-Variable -Name tlsCode -ErrorAction SilentlyContinue) {
        [void]$iss.Variables.Add((New-Object $varType('tlsCode', (Get-Variable tlsCode).Value, $null)))
    }

    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($NetInfoObj, $ConfigObj)
        $script:NetInfo = $NetInfoObj
        $script:Config = $ConfigObj
        $script:ExtraDiag = [ordered]@{
            BypassTools     = @{ Detected = $false; Names = @() }
            Dns             = @()
            Quic            = $null
            Tcp16           = $null
            IpVsSni         = $null
            RstStats        = @{ RstCh = 0; RstPost = 0 }
            Recommendations = @()
        }
        $script:TlsScannerLoaded = $true
        $script:TlsScannerLoadFailed = $false
        Invoke-PostScanExtrasBody
    }).AddArgument($script:NetInfo).AddArgument($script:Config)

    $script:ExtrasRunspace = $rs
    $script:ExtrasPs = $ps
    $script:ExtrasHandle = $ps.BeginInvoke()
    $script:ExtrasPending = $true
    $script:ExtrasStep = 1
    Write-DebugLog "EXTRA started async (in-process runspace)" "INFO"
}

function Update-ExtrasFromCompletedAsync {
    if (-not $script:ExtrasPending) { return $false }
    $ps = $script:ExtrasPs
    $handle = $script:ExtrasHandle
    if ($null -eq $ps -or $null -eq $handle) {
        $script:ExtrasPending = $false
        $script:ExtrasStep = 0
        return $false
    }
    if (-not $handle.IsCompleted) { return $false }

    $snap = $null
    try {
        $raw = $ps.EndInvoke($handle)
        $snap = if ($raw -is [System.Array] -and $raw.Count -gt 0) { $raw[0] } else { $raw }
    } catch {
        Write-DebugLog "EXTRA async EndInvoke: $_" "WARN"
    }
    try { $ps.Dispose() } catch { }
    if ($script:ExtrasRunspace) {
        try { $script:ExtrasRunspace.Close() } catch { }
        try { $script:ExtrasRunspace.Dispose() } catch { }
    }
    $script:ExtrasPs = $null
    $script:ExtrasHandle = $null
    $script:ExtrasRunspace = $null
    $script:ExtrasPending = $false
    $script:ExtrasStep = 0

    if ($snap) {
        try {
            if ($null -ne $snap.Dns) { $script:ExtraDiag.Dns = $snap.Dns }
            if ($null -ne $snap.Quic) { $script:ExtraDiag.Quic = $snap.Quic }
            if ($null -ne $snap.Tcp16) { $script:ExtraDiag.Tcp16 = $snap.Tcp16 }
            if ($null -ne $snap.IpVsSni) { $script:ExtraDiag.IpVsSni = $snap.IpVsSni }
        } catch {
            Write-DebugLog "EXTRA merge: $_" "WARN"
        }
    }
    try { Complete-PostScanExtrasFinalize } catch { Write-DebugLog "EXTRA finalize: $_" "WARN" }
    try { Draw-StatusBar } catch { }
    Write-DebugLog "EXTRA async completed" "INFO"
    return $true
}

function Get-RstPhaseFromException {
    param([string]$Message, [bool]$AuthStarted = $false, [bool]$AuthCompleted = $false)
    if ($Message -match "TLS12_TIMEOUT|TcpTimeout|timeout") { return "DRP" }
    if ($Message -match "reset|сброс|forcibly|closed|разорвано") {
        if ($AuthCompleted) { return "RST_POST" }
        return "RST_CH"
    }
    return "DRP"
}

function Invoke-DnsCompareProbe {
    Write-DebugLog "EXTRA: DNS system vs DoH" "INFO"
    $hosts = @($CONST.DnsProbe.Hosts)
    try {
        if ($script:NetInfo -and $script:NetInfo.CDN) { $hosts += [string]$script:NetInfo.CDN }
    } catch { }
    $hosts = $hosts | Select-Object -Unique
    $rows = @()
    foreach ($h in $hosts) {
        $sysIps = @()
        $sysStatus = "OK"
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($h)
            $sysIps = @($addrs | ForEach-Object { $_.IPAddressToString })
            $priv = $sysIps | Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.|0\.0\.0\.0)' }
            if ($priv -and $priv.Count -gt 0 -and $sysIps.Count -eq $priv.Count) { $sysStatus = "SPOOF_SUSPECT" }
        } catch {
            $sysStatus = "TIMEOUT"
        }

        $dohIps = @()
        $dohStatus = "OK"
        $dohOk = $false
        foreach ($dohBase in $CONST.DnsProbe.DohUrls) {
            try {
                $url = if ($dohBase -match 'dns\.google') {
                    ($dohBase + '?name=' + $h + '&type=A')
                } else {
                    ($dohBase + '?name=' + $h + '&type=A')
                }
                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.Method = "GET"
                $req.Accept = "application/dns-json"
                $req.Timeout = [int]$CONST.DnsProbe.TimeoutMs
                $req.UserAgent = if ($script:UserAgent) { $script:UserAgent } else { "YT-DPI/3.0" }
                $resp = $req.GetResponse()
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $json = $sr.ReadToEnd()
                $resp.Close()
                $obj = $json | ConvertFrom-Json
                if ($obj.Answer) {
                    foreach ($ans in @($obj.Answer)) {
                        if ($ans.type -eq 1 -and $ans.data) { $dohIps += [string]$ans.data }
                    }
                }
                $dohOk = $true
                break
            } catch {
                $dohStatus = "DOH_BLOCK"
            }
        }
        if (-not $dohOk) { $dohStatus = "DOH_BLOCK" }
        elseif ($dohIps.Count -eq 0) { $dohStatus = "TIMEOUT" }

        $verdict = "OK"
        if ($sysStatus -eq "SPOOF_SUSPECT") { $verdict = "SPOOF_SUSPECT" }
        elseif ($sysStatus -eq "TIMEOUT" -and $dohStatus -eq "OK") { $verdict = "MISMATCH" }
        elseif ($dohStatus -eq "DOH_BLOCK") { $verdict = "DOH_BLOCK" }
        elseif ($sysStatus -eq "OK" -and $dohStatus -eq "OK" -and $sysIps.Count -gt 0 -and $dohIps.Count -gt 0) {
            $overlap = $sysIps | Where-Object { $dohIps -contains $_ }
            if (-not $overlap) { $verdict = "MISMATCH" }
        }

        $rows += [PSCustomObject]@{
            Host = $h; System = ($sysIps -join ","); Doh = ($dohIps -join ","); Status = $verdict
        }
    }
    $script:ExtraDiag.Dns = $rows
    return $rows
}

function New-QuicInitialProbeBytes {
    # Minimal UDP payload resembling a QUIC long-header Initial (not a full valid CH).
    $buf = New-Object byte[] 1250
    $rng = New-Object System.Random
    $rng.NextBytes($buf)
    $buf[0] = 0xC0
    $buf[1] = 0x00; $buf[2] = 0x00; $buf[3] = 0x00; $buf[4] = 0x01
    return $buf
}

function Invoke-QuicUdpProbe {
    Write-DebugLog "EXTRA: QUIC UDP:443" "INFO"
    $port = [int]$CONST.Quic.Port
    $timeout = [int]$CONST.Quic.TimeoutMs
    $payload = New-QuicInitialProbeBytes

    function Test-OneQuicHost([string]$hostName) {
        $ip = $null
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostName) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                Select-Object -First 1)
        } catch { }
        if (-not $ip) {
            return [PSCustomObject]@{ Host = $hostName; Ip = $null; Status = "N/A"; Detail = "no_ipv4" }
        }
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient($ip.AddressFamily)
            $udp.Client.ReceiveTimeout = $timeout
            $udp.Client.SendTimeout = $timeout
            $ep = New-Object System.Net.IPEndPoint($ip, $port)
            [void]$udp.Send($payload, $payload.Length, $ep)
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            try {
                $null = $udp.Receive([ref]$remote)
                return [PSCustomObject]@{ Host = $hostName; Ip = $ip.IPAddressToString; Status = "QUIC_OK"; Detail = "response" }
            } catch [System.Net.Sockets.SocketException] {
                # No response is common; treat as soft OK if send succeeded (UDP may be filtered silently).
                # Distinguish: ICMP unreachable often surfaces as SocketException ConnectionReset.
                if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionReset) {
                    return [PSCustomObject]@{ Host = $hostName; Ip = $ip.IPAddressToString; Status = "QUIC_BLOCK"; Detail = "icmp_or_reset" }
                }
                return [PSCustomObject]@{ Host = $hostName; Ip = $ip.IPAddressToString; Status = "QUIC_TIMEOUT"; Detail = "no_reply" }
            }
        } catch {
            return [PSCustomObject]@{ Host = $hostName; Ip = $(if ($ip) { $ip.IPAddressToString } else { $null }); Status = "N/A"; Detail = $_.Exception.Message }
        } finally {
            if ($udp) { try { $udp.Close() } catch { } }
        }
    }

    $targetHost = [string]$CONST.Quic.TargetHost
    $controlHost = [string]$CONST.Quic.ControlHost
    try {
        if ($script:NetInfo -and $script:NetInfo.CDN) { $targetHost = [string]$script:NetInfo.CDN }
    } catch { }

    $yt = Test-OneQuicHost $targetHost
    $ctrl = Test-OneQuicHost $controlHost
    $summary = "QUIC_OK"
    if ($yt.Status -eq "QUIC_BLOCK") { $summary = "QUIC_BLOCK" }
    elseif ($yt.Status -eq "QUIC_TIMEOUT" -and $ctrl.Status -eq "QUIC_OK") { $summary = "QUIC_BLOCK" }
    elseif ($yt.Status -eq "QUIC_TIMEOUT" -and $ctrl.Status -eq "QUIC_TIMEOUT") { $summary = "QUIC_TIMEOUT" }
    elseif ($yt.Status -eq "N/A") { $summary = "N/A" }

    $result = [PSCustomObject]@{ Summary = $summary; Youtube = $yt; Control = $ctrl }
    $script:ExtraDiag.Quic = $result
    return $result
}

function Invoke-Tcp16Probe {
    Write-DebugLog "EXTRA: TCP16 bulk-drop" "INFO"
    $hostName = [string]$CONST.Tcp16.HostFallback
    try {
        if ($script:NetInfo -and $script:NetInfo.CDN) { $hostName = [string]$script:NetInfo.CDN }
    } catch { }
    $ip = $null
    try {
        $ip = ([System.Net.Dns]::GetHostAddresses($hostName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1)
    } catch { }
    if (-not $ip) {
        $r = [PSCustomObject]@{ Host = $hostName; Status = "N/A"; Bytes = 0; Detail = "no_ipv4" }
        $script:ExtraDiag.Tcp16 = $r
        return $r
    }

    $tcp = $null; $ssl = $null
    $read = 0
    $status = "TCP16_FAIL"
    $detail = ""
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
        $ar = $tcp.BeginConnect($ip, 443, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne([int]$CONST.Tcp16.TimeoutMs)) { throw "connect_timeout" }
        $tcp.EndConnect($ar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.ReadTimeout = [int]$CONST.Tcp16.TimeoutMs
        $ssl.WriteTimeout = [int]$CONST.Tcp16.TimeoutMs
        $ssl.AuthenticateAsClient($hostName)
        $req = "GET / HTTP/1.1`r`nHost: $hostName`r`nConnection: close`r`nUser-Agent: YT-DPI/3.0`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($bytes, 0, $bytes.Length)
        $buf = New-Object byte[] 4096
        $target = [int]$CONST.Tcp16.BytesTarget
        while ($read -lt $target) {
            $n = $ssl.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $read += $n
        }
        $minB = [int]$CONST.Tcp16.DropMinBytes
        $maxB = [int]$CONST.Tcp16.DropMaxBytes
        if ($read -ge $target) {
            $status = "TCP16_OK"; $detail = "full_read"
        } elseif ($read -ge $minB -and $read -le $maxB) {
            $status = "TCP16_DROP"; $detail = "drop_window"
        } elseif ($read -gt 0 -and $read -lt $minB) {
            $status = "TCP16_FAIL"; $detail = "early_close"
        } else {
            $status = "TCP16_FAIL"; $detail = "no_data"
        }
    } catch {
        $m = $_.Exception.Message
        if ($m -match "reset|forcibly|closed") {
            $minB = [int]$CONST.Tcp16.DropMinBytes
            $maxB = [int]$CONST.Tcp16.DropMaxBytes
            if ($read -ge $minB -and $read -le $maxB) { $status = "TCP16_DROP"; $detail = "rst_in_window" }
            else { $status = "TCP16_FAIL"; $detail = "rst" }
        } else {
            $status = "TCP16_FAIL"; $detail = $m
        }
    } finally {
        if ($ssl) { try { $ssl.Close() } catch { } }
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
    $r = [PSCustomObject]@{ Host = $hostName; Ip = $ip.IPAddressToString; Status = $status; Bytes = $read; Detail = $detail }
    $script:ExtraDiag.Tcp16 = $r
    return $r
}

function Invoke-IpVsSniProbe {
    Write-DebugLog "EXTRA: IP vs SNI" "INFO"
    if (-not (Ensure-TlsScannerLoaded)) {
        $r = [PSCustomObject]@{ Status = "N/A"; Detail = "tls_engine_unavailable" }
        $script:ExtraDiag.IpVsSni = $r
        return $r
    }
    $hostName = "www.youtube.com"
    try { if ($script:NetInfo -and $script:NetInfo.CDN) { $hostName = [string]$script:NetInfo.CDN } } catch { }
    $ip = $null
    try {
        $ip = ([System.Net.Dns]::GetHostAddresses($hostName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1)
    } catch { }
    if (-not $ip) {
        $r = [PSCustomObject]@{ Status = "N/A"; Detail = "no_ipv4" }
        $script:ExtraDiag.IpVsSni = $r
        return $r
    }
    $ipStr = $ip.IPAddressToString
    $ytSni = [string]$CONST.IpVsSni.YoutubeSni
    $ctrlSni = [string]$CONST.IpVsSni.ControlSni
    $to = [int]$CONST.IpVsSni.TimeoutMs

    function Probe-Sni([string]$sni) {
        try {
            $cell = [TlsScanner]::TestT13($ipStr, $sni, "", 0, "", "", $to)
            return [string]$cell
        } catch {
            $m = $_.Exception.Message
            if ($m -match "reset|forcibly") { return "RST" }
            return "DRP"
        }
    }

    $yt = Probe-Sni $ytSni
    $ctrl = Probe-Sni $ctrlSni
    $status = "OK"
    if (($yt -eq "RST" -or $yt -eq "DRP") -and ($ctrl -eq "RST" -or $ctrl -eq "DRP")) { $status = "IP_BLOCK" }
    elseif (($yt -eq "RST" -or $yt -eq "DRP") -and ($ctrl -eq "OK" -or $ctrl -eq "N/A")) { $status = "SNI_BLOCK" }
    elseif ($yt -eq "OK" -and ($ctrl -eq "RST" -or $ctrl -eq "DRP")) { $status = "MIXED" }
    elseif ($yt -eq "OK") { $status = "OK" }
    else { $status = "MIXED" }

    $r = [PSCustomObject]@{
        Ip = $ipStr; YoutubeSni = $ytSni; ControlSni = $ctrlSni
        YoutubeCell = $yt; ControlCell = $ctrl; Status = $status
    }
    $script:ExtraDiag.IpVsSni = $r
    return $r
}

function Build-Recommendations {
    param($ScanRows, $Extra)
    $recs = New-Object System.Collections.Generic.List[string]
    $dpi = 0; $thr = 0; $ipb = 0; $rstCh = 0
    if ($ScanRows) {
        foreach ($r in @($ScanRows)) {
            if (-not $r) { continue }
            switch ($r.Verdict) {
                "DPI RESET" { $dpi++ }
                "DPI BLOCK" { $dpi++ }
                "THROTTLED" { $thr++ }
                "IP BLOCK" { $ipb++ }
            }
            if ($r.RstPhase12 -eq "RST_CH" -or $r.RstPhase13 -eq "RST_CH") { $rstCh++ }
        }
    }
    if ($Extra.RstStats) {
        $rstCh = [Math]::Max($rstCh, [int]$Extra.RstStats.RstCh)
    }
    if ($rstCh -gt 0) {
        [void]$recs.Add("RST во время ClientHello (RST_CH) на части хостов: классическая инъекция SNI/DPI — TLS-путь активно сбрасывается.")
    }
    if ($thr -gt 0) {
        [void]$recs.Add("Строки THROTTLED: одна версия TLS работает, другая нет — попробуйте принудительный TLS 1.2 в клиентах или отключите особенности HTTP/3.")
    }
    if ($dpi -gt 0) {
        [void]$recs.Add("DPI RESET/BLOCK на целях YouTube: похоже, фильтр провайдера смотрит SNI; сравните со сканом через прокси (P).")
    }
    if ($ipb -gt 0 -and $ipb -eq @($ScanRows | Where-Object { $_ }).Count) {
        [void]$recs.Add("Везде IP BLOCK: сначала проверьте базовую связность/DNS, прежде чем списывать на DPI.")
    }
    if ($Extra.Dns) {
        $bad = @($Extra.Dns | Where-Object { $_.Status -ne "OK" })
        if ($bad.Count -gt 0) {
            [void]$recs.Add("Проблемы DNS ($(($bad | ForEach-Object { $_.Host + '=' + $_.Status }) -join '; ')): попробуйте DoH/доверенный резолвер или поправьте системный DNS.")
        }
    }
    if ($Extra.Quic -and $Extra.Quic.Summary -eq "QUIC_BLOCK") {
        [void]$recs.Add("QUIC/UDP:443 похоже заблокирован: отключите HTTP/3 в браузере, чтобы YouTube ушёл на TCP/TLS.")
    }
    if ($Extra.Tcp16 -and $Extra.Tcp16.Status -eq "TCP16_DROP") {
        [void]$recs.Add("Обрыв TCP на 16–20 КБ у CDN: после handshake большой объём рвётся — типичный паттерн ТСПУ на CDN.")
    }
    if ($Extra.IpVsSni) {
        switch ($Extra.IpVsSni.Status) {
            "IP_BLOCK" { [void]$recs.Add("Блокировка по адресу IP CDN: смена SNI не поможет — нужен другой маршрут/прокси.") }
            "SNI_BLOCK" { [void]$recs.Add("Блокировка по SNI (YouTube SNI падает, контрольный отличается): DPI по имени, не чистый IP-бан.") }
        }
    }
    if ($recs.Count -eq 0) {
        [void]$recs.Add("Крупных аномалий DPI/DNS/QUIC в доп. наборе нет — если YouTube всё ещё тормозит, проверьте CDN/буферизацию и HTTP/3 в браузере.")
    }
    $script:ExtraDiag.Recommendations = @($recs)
    return @($recs)
}

function Invoke-PostScanExtras {
    # Batch / sync path: run all probes; no STATUS tip (tips live under [E] only).
    if ($script:NoExtras) {
        Write-DebugLog "EXTRA skipped (--no-extras)" "INFO"
        $script:ExtrasStep = 0
        $script:ExtrasPending = $false
        return
    }
    if (-not $script:BatchMode) {
        Draw-StatusBar -Message "[ EXTRA ] DNS / QUIC / TCP16 / IP-vs-SNI..." -Fg "Black" -Bg "Cyan"
    } else {
        Write-Host "[ EXTRA ] Running DNS / QUIC / TCP16 / IP-vs-SNI..."
    }
    try { Invoke-PostScanExtrasBody | Out-Null } catch { Write-DebugLog "EXTRA body: $_" "WARN" }
    Complete-PostScanExtrasFinalize
    $script:ExtrasStep = 0
    $script:ExtrasPending = $false
    if (-not $script:BatchMode) {
        Draw-StatusBar
    }
}

function Get-BatchExitCode {
    if (-not (Test-InternetAvailable)) { return 2 }
    $sev = 0
    if ($script:LastScanResults) {
        foreach ($r in @($script:LastScanResults)) {
            if (-not $r) { continue }
            if ($r.Verdict -in @("DPI RESET", "DPI BLOCK", "THROTTLED", "IP BLOCK")) { $sev = 1 }
        }
    }
    if ($script:ExtraDiag.Quic -and $script:ExtraDiag.Quic.Summary -eq "QUIC_BLOCK") { $sev = 1 }
    if ($script:ExtraDiag.Tcp16 -and $script:ExtraDiag.Tcp16.Status -eq "TCP16_DROP") { $sev = 1 }
    if ($script:ExtraDiag.Dns) {
        foreach ($d in @($script:ExtraDiag.Dns)) {
            if ($d.Status -ne "OK") { $sev = 1 }
        }
    }
    if ($script:ExtraDiag.IpVsSni -and $script:ExtraDiag.IpVsSni.Status -in @("IP_BLOCK", "SNI_BLOCK")) { $sev = 1 }
    return $sev
}

function Export-YtDpiJsonReport {
    param([string]$Path)
    if (-not $Path) { return }
    $targets = @()
    if ($script:Targets -and $script:LastScanResults) {
        for ($i = 0; $i -lt $script:Targets.Count; $i++) {
            $res = $script:LastScanResults[$i]
            $targets += [ordered]@{
                domain = $script:Targets[$i]
                ip = $(if ($res) { $res.IP } else { $null })
                http = $(if ($res) { $res.HTTP } else { $null })
                t12 = $(if ($res) { $res.T12 } else { $null })
                t13 = $(if ($res) { $res.T13 } else { $null })
                rstPhase12 = $(if ($res) { $res.RstPhase12 } else { $null })
                rstPhase13 = $(if ($res) { $res.RstPhase13 } else { $null })
                lat = $(if ($res) { $res.Lat } else { $null })
                verdict = $(if ($res) { $res.Verdict } else { $null })
            }
        }
    }
    $doc = [ordered]@{
        version = $scriptVersion
        timestamp = (Get-Date).ToString("o")
        net = @{
            isp = $(if ($script:NetInfo) { $script:NetInfo.ISP } else { $null })
            loc = $(if ($script:NetInfo) { $script:NetInfo.LOC } else { $null })
            dns = $(if ($script:NetInfo) { $script:NetInfo.DNS } else { $null })
            cdn = $(if ($script:NetInfo) { $script:NetInfo.CDN } else { $null })
        }
        bypassTools = $script:ExtraDiag.BypassTools
        targets = $targets
        extra = @{
            dns = $script:ExtraDiag.Dns
            quic = $script:ExtraDiag.Quic
            tcp16 = $script:ExtraDiag.Tcp16
            ipVsSni = $script:ExtraDiag.IpVsSni
            rstStats = $script:ExtraDiag.RstStats
        }
        recommendations = @($script:ExtraDiag.Recommendations)
    }
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-DebugLog "JSON report: $Path" "INFO"
}

function Format-ExtraDiagText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== ДОП. ДИАГНОСТИКА ===")
    if ($script:ExtraDiag.Dns) {
        [void]$sb.AppendLine("DNS: система vs DoH:")
        foreach ($d in @($script:ExtraDiag.Dns)) {
            [void]$sb.AppendLine(("  {0}: {1}  sys=[{2}] doh=[{3}]" -f $d.Host, $d.Status, $d.System, $d.Doh))
        }
    } else {
        [void]$sb.AppendLine("DNS: (нет данных — выполните скан Enter)")
    }
    if ($script:ExtraDiag.Quic) {
        $q = $script:ExtraDiag.Quic
        [void]$sb.AppendLine(("QUIC: {0}  yt={1}/{2}  ctrl={3}/{4}" -f $q.Summary, $q.Youtube.Status, $q.Youtube.Ip, $q.Control.Status, $q.Control.Ip))
    } else {
        [void]$sb.AppendLine("QUIC: (нет данных)")
    }
    if ($script:ExtraDiag.Tcp16) {
        $t = $script:ExtraDiag.Tcp16
        [void]$sb.AppendLine(("TCP16: {0}  host={1} ip={2} bytes={3} ({4})" -f $t.Status, $t.Host, $t.Ip, $t.Bytes, $t.Detail))
    } else {
        [void]$sb.AppendLine("TCP16: (нет данных)")
    }
    if ($script:ExtraDiag.IpVsSni) {
        $x = $script:ExtraDiag.IpVsSni
        [void]$sb.AppendLine(("IP vs SNI: {0}  ip={1} yt={2} ctrl={3}" -f $x.Status, $x.Ip, $x.YoutubeCell, $x.ControlCell))
    } else {
        [void]$sb.AppendLine("IP vs SNI: (нет данных)")
    }
    if ($script:ExtraDiag.RstStats) {
        [void]$sb.AppendLine(("Фазы RST: CH={0} POST={1}" -f $script:ExtraDiag.RstStats.RstCh, $script:ExtraDiag.RstStats.RstPost))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=== РЕКОМЕНДАЦИИ ===")
    $recs = @($script:ExtraDiag.Recommendations)
    if ($recs.Count -eq 0) {
        [void]$sb.AppendLine("* (пока пусто — выполните скан Enter)")
    } else {
        foreach ($r in $recs) {
            [void]$sb.AppendLine(("* {0}" -f $r))
        }
    }
    return $sb.ToString()
}

function Invoke-BatchSuite {
    Write-Host "[ BATCH ] YT-DPI $scriptVersion headless suite"
    Show-BypassWarningBanner
    if (-not (Test-InternetAvailable)) {
        Write-Host "[ ERROR ] No internet"
        if ($script:JsonReportPath) { Export-YtDpiJsonReport -Path $script:JsonReportPath }
        exit 2
    }
    $null = Ensure-TlsScannerLoaded
    $script:NetInfo = Get-NetworkInfo
    if (-not (Test-NetInfoUsable $script:NetInfo)) {
        $script:NetInfo = Get-ReadyNetInfo
    }
    $null = Set-NetInfoCacheIfUsable $script:NetInfo
    Initialize-Targets
    $script:Targets = Get-Targets -NetInfo $script:NetInfo
    Write-Host ("[ SCAN ] {0} targets..." -f $script:Targets.Count)
    $scanResult = Start-ScanWithAnimation $script:Targets $global:ProxyConfig $false
    if ($scanResult.CommitResults -ne $false) {
        $script:LastScanResults = $scanResult.Results
    }
    $script:HasCompletedScan = (-not $scanResult.Aborted) -or $script:HasCompletedScan
    Invoke-PostScanExtras
    $txt = if ($script:TxtReportPath) { $script:TxtReportPath } else { Join-Path $script:ParentDirForReports $CONST.Batch.DefaultTxtName }
    Save-ScanReportToPath -Path $txt -Silent
    if ($script:JsonReportPath) { Export-YtDpiJsonReport -Path $script:JsonReportPath }
    $code = Get-BatchExitCode
    Write-Host ("[ BATCH ] done exit={0} json={1}" -f $code, $script:JsonReportPath)
    exit $code
}

function Save-ScanReportToPath {
    param([string]$Path, [switch]$Silent)
    $logPath = $Path
    if (-not $logPath) {
        $logPath = Join-Path -Path (Get-Location).Path -ChildPath "YT-DPI_Report.txt"
    }
    $logContent = "=== YT-DPI REPORT v$scriptVersion ===`r`n"
    $logContent += "TIME: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $logContent += "ISP:  $($script:NetInfo.ISP) ($($script:NetInfo.LOC))`r`n"
    $logContent += "DNS:  $($script:NetInfo.DNS)`r`n"
    $logContent += "CDN:  $($script:NetInfo.CDN)`r`n"
    $logContent += "PROXY: $(if($global:ProxyConfig.Enabled) {"$($global:ProxyConfig.Type) $($global:ProxyConfig.Host):$($global:ProxyConfig.Port)"} else {"OFF"})`r`n"
    $logContent += "-" * 90 + "`r`n"
    $logContent += "{0,-38} {1,-16} {2,-6} {3,-8} {4,-8} {5,-6} {6}`r`n" -f "TARGET DOMAIN", "IP ADDRESS", "HTTP", "TLS 1.2", "TLS 1.3", "LAT (ms)", "RESULT"
    $logContent += "-" * 90 + "`r`n"

    if ($script:LastScanResults -and $script:LastScanResults.Count -gt 0) {
        foreach ($i in 0..($script:Targets.Count-1)) {
            $res = $script:LastScanResults[$i]
            if ($res -and $res.Verdict -ne "SCAN ABORTED") {
                $ip = if($global:ProxyConfig.Enabled) {"[ PROXIED ]"} else {$res.IP}
                $logContent += "{0,-38} {1,-16} {2,-6} {3,-8} {4,-8} {5,-6} {6}`r`n" -f $script:Targets[$i], $ip, $res.HTTP, $res.T12, $res.T13, $res.Lat, $res.Verdict
            } else {
                $logContent += "{0,-38} {1,-16} {2,-6} {3,-8} {4,-8} {5,-6} {6}`r`n" -f $script:Targets[$i], "NOT SCANNED", "---", "---", "---", "---", "NO DATA"
            }
        }
    } else {
        $logContent += "`r`n[!] No scan results available. Please run a scan first (press ENTER).`r`n"
    }
    $logContent += Format-ExtraDiagText
    [IO.File]::WriteAllText($logPath, $logContent, [System.Text.Encoding]::UTF8)
    if (-not $Silent) {
        if ($script:LastScanResults -and $script:LastScanResults.Count -gt 0) {
            Draw-StatusBar -Message "[ SUCCESS ] SAVED TO: $logPath" -Fg "Black" -Bg "Green"
        } else {
            Draw-StatusBar -Message "[ WARNING ] NO SCAN DATA. SAVED EMPTY REPORT TO: $logPath" -Fg "Black" -Bg "Yellow"
        }
    }
    return $logPath
}

function Invoke-HelpAction {
    Write-DebugLog "Показ справки"
    Show-HelpMenu
    Restore-MainUiConsole
    Update-ConsoleSize
    Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
    Draw-StatusBar
    Clear-KeyBuffer
}

function Invoke-UpdateAction {
    Write-DebugLog "Запуск обновления"
    Invoke-Update -Repo "Shiperoid/YT-DPI" -Config $script:Config

    # Вместо полной перерисовки Draw-UI просто восстанавливаем статус-бар
    Draw-StatusBar
    Clear-KeyBuffer
}

function Invoke-ProxyMenuAction {
    Write-DebugLog "Открыто меню прокси"
    $proxyCtxBefore = Get-GeoProxyKey
    Show-ProxyMenu
    if ((Get-GeoProxyKey) -ne $proxyCtxBefore) {
        $newNetInfo = Get-NetworkInfo
        if (Test-NetInfoUsable $newNetInfo) {
            $script:NetInfo = $newNetInfo
            $null = Set-NetInfoCacheIfUsable $script:NetInfo
        }
        Save-Config $script:Config
        $script:Targets = Get-Targets -NetInfo $script:NetInfo
    }
    Restore-MainUiConsole
    Update-ConsoleSize
    Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
    Draw-StatusBar
    Clear-KeyBuffer
}

function Invoke-SettingsAction {
    Write-DebugLog "Открыты настройки"
    Show-SettingsMenu
    Restore-MainUiConsole
    Update-ConsoleSize
    Draw-UI $script:NetInfo $script:Targets (Get-MainTableResults) $true
    Draw-StatusBar
    Clear-KeyBuffer
}

function Invoke-ScanAction {
    Write-DebugLog "Запуск сканирования по Enter (ULTRA-FAST MODE)"

    if ($script:ScanPhase -ne "Idle") {
        Write-DebugLog "Scan already in phase=$($script:ScanPhase) — ignore Enter" "INFO"
        return
    }
    $script:ScanPhase = "Running"
    Stop-DeferredPostScanExtras
    $script:ExtrasStep = 0

    try {
    # === МГНОВЕННАЯ ПРОВЕРКА ИНТЕРНЕТА ===
    Draw-StatusBar -Message "[ CHECK ] Проверка интернета..." -Fg "Black" -Bg "Cyan"
    if (-not (Test-InternetAvailable)) {
        Draw-StatusBar -Message "[ ERROR ] НЕТ ИНТЕРНЕТА! ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ." -Fg "Black" -Bg "Red"
        Start-Sleep -Seconds 2
        Draw-StatusBar
        Clear-KeyBuffer
        return
    }

    # === МГНОВЕННАЯ ЗАГРУЗКА NETINFO (ИЗ КЭША) ===
    Draw-StatusBar -Message "[ CACHE ] Загрузка сетевых данных..." -Fg "Black" -Bg "Cyan"
    $scanPrep = Update-TargetsBeforeScan

    # === ОБНОВЛЕНИЕ ТАБЛИЦЫ ТОЛЬКО ЕСЛИ ИЗМЕНИЛИСЬ ЦЕЛИ/РАЗМЕР ===
    $placeholderRowsVisible = $false
    if ($scanPrep.NeedTableRefresh) {
        $rowsForDraw = $scanPrep.RowsBeforeScan
        if ($null -eq $rowsForDraw -and -not $script:HasCompletedScan) {
            $rowsForDraw = New-PlaceholderResultRows -Targets $script:Targets
            $placeholderRowsVisible = $true
        }
        Draw-UI $script:NetInfo $script:Targets $rowsForDraw $scanPrep.NeedClear
    }
    elseif (-not $script:HasCompletedScan) {
        $placeholderRowsVisible = $true
    }

    # === ЛЕНИВАЯ ЗАГРУЗКА TLS ENGINE ===
    if (-not (Test-TlsScannerReady) -and -not $script:TlsScannerLoadFailed) {
        Draw-StatusBar -Message "[ ENGINE ] Loading TLS scanner..." -Fg "Black" -Bg "Yellow"
    }
    if (-not (Ensure-TlsScannerLoaded)) {
        Draw-StatusBar -Message "[ ERROR ] TLS scanner failed to load. Scan cancelled." -Fg "White" -Bg "Red"
        Start-Sleep -Seconds 2
        Draw-StatusBar
        return
    }

    # === МГНОВЕННЫЙ СТАРТ СКАНА ===
    Draw-StatusBar -Message "[ SCAN ] Запуск сканирования..." -Fg "Black" -Bg "Green"

    $scanResult = Start-ScanWithAnimation $script:Targets $global:ProxyConfig $placeholderRowsVisible
    $script:ScanPhase = "Finishing"

    if ($scanResult.CommitResults -ne $false) {
        $script:LastScanResults = $scanResult.Results
    }
    Sync-DynamicColPosFromLayout
    Update-UiConsoleSnapshot

    if ($scanResult.Aborted) {
        Draw-StatusBar -Message "[ ABORTED ] Скан прерван." -Fg "Black" -Bg "Red"
        $script:ExtrasStep = 0
    } else {
        $script:HasCompletedScan = $true
        Update-NetInfoFromCompletedJob
        # Idle STATUS immediately — EXTRA deferred so keys work right after the table.
        Draw-StatusBar
        if ($script:BatchMode -or $script:NoExtras) {
            Invoke-PostScanExtras
        } else {
            Start-DeferredPostScanExtras
        }
    }

    Clear-KeyBuffer
    }
    finally {
        $script:ScanPhase = "Idle"
    }
}

# ====================================================================================
# ГЛАВНЫЙ ЦИКЛ ПРОГРАММЫ (ENGINE START)
# ====================================================================================

function Initialize-AppState {
    # 1. Загрузка конфигурации (Мгновенно)
    $script:Config = Load-Config
    $global:ProxyConfig = $script:Config.Proxy

    if ($null -eq $script:Config.WarnBypassTools -or [bool]$script:Config.WarnBypassTools) {
        $script:Config | Add-Member -MemberType NoteProperty -Name "WarnBypassTools" -Value $false -Force
        Save-Config $script:Config
    }
    foreach ($pair in @(
            @{ N = "UiShowLatBars"; V = $true },
            @{ N = "UiExtraStrip"; V = $false },
            @{ N = "PathMaxHops"; V = 15 },
            @{ N = "PathSamples"; V = 3 },
            @{ N = "PathIntervalMs"; V = 200 },
            @{ N = "GraphWidth"; V = 10 },
            @{ N = "GraphCharset"; V = "Blocks" }
        )) {
        if ($null -eq $script:Config.($pair.N)) {
            $script:Config | Add-Member -MemberType NoteProperty -Name $pair.N -Value $pair.V -Force
        }
    }
    # ExtraStrip retired from TUI — force off so old configs stop painting a third footer.
    if ($script:Config.UiExtraStrip) {
        $script:Config | Add-Member -MemberType NoteProperty -Name "UiExtraStrip" -Value $false -Force
        Save-Config $script:Config
    }

    # 1b. Инициализация настройки UseCustomTargets, если отсутствует
    if ($null -eq $script:Config.UseCustomTargets) {
        $targetsFile = Join-Path (Split-Path -Parent $script:OriginalFilePath) "targets.txt"
        $script:Config | Add-Member -MemberType NoteProperty -Name "UseCustomTargets" -Value (Test-Path $targetsFile) -Force
        Save-Config $script:Config
    }

    # 2. Инициализация целей (это установит $script:BaseTargets и $script:CustomTargetsLoaded)
    Initialize-Targets

    Write-DebugLogSessionHeaderIfNeeded
    $script:Config.RunCount++

    # 3. Синхронизация DNS кэша
    Sync-DnsCacheFromConfig
    Initialize-DisableBrokenParallelTlsTasks

    if ($script:BatchMode) {
        Initialize-ScannerEngines
        Invoke-BatchSuite
        return
    }

    # 4. Выбираем готовые данные из NetInfo
    $script:NetInfo = Get-ReadyNetInfo
    $script:Targets = Get-Targets -NetInfo $script:NetInfo
    [Console]::Clear()
    Draw-UI $script:NetInfo $script:Targets $null $false
    Draw-StatusBar
    Show-BypassWarningBanner
    Initialize-ScannerEngines

    # 5. Обновление сети в фоне
    if ($script:Config.NetCacheStale -or $script:Config.RunCount -le 1 -or -not (Test-NetInfoUsable $script:NetInfo)) {
        Start-BackgroundNetInfoUpdate
    }

    # 6. Проверка обновлений
    if ($script:Config.RunCount % 10 -eq 0) {
        $newVer = Check-UpdateVersion -Repo "Shiperoid/YT-DPI" -LastCheckedVersion $script:Config.LastCheckedVersion
        if ($newVer) {
            Draw-StatusBar -Message "[ UPDATE ] NEW VERSION v$newVer AVAILABLE! PRESS 'U' TO UPDATE." -Fg "White" -Bg "DarkMagenta"
            Start-Sleep -Seconds 3
        }
    }

    Draw-StatusBar
    Write-DebugLog "--- СИСТЕМА ГОТОВА ---" "INFO"
    Clear-KeyBuffer
    $FirstRun = $false
}

Draw-StatusBar
Write-DebugLog "--- СИСТЕМА ГОТОВА ---" "INFO"
Clear-KeyBuffer
$FirstRun = $false



function Start-MainLoop {
    $FirstRun = $false
while ($true) {
    if ($FirstRun) {
        Write-DebugLog "Первый запуск: получение сетевой информации"
        $script:NetInfo = Get-NetworkInfo
        $script:Targets = Get-Targets -NetInfo $script:NetInfo
        Write-DebugLog "Целей: $($script:Targets.Count)"
        Draw-UI $script:NetInfo $script:Targets $null $true
        Draw-StatusBar
        $FirstRun = $false
    }


    $k = Read-MainLoopKey
    if ($script:UiCursorHidden -ne $true) {
        [Console]::CursorVisible = $false
        $script:UiCursorHidden = $true
    }
    try { [Console]::CursorSize = 1 } catch { }

        # Scroll first — skip Force-resize check (saves latency before paint).
        if (Test-IsTableScrollKey $k) {
            $null = Invoke-CoalescedTableScroll -FirstKey $k
            continue
        }

    $null = Invoke-FullUiRedrawIfConsoleResized -Force

        if ($k -eq "Q" -or $k -eq "Escape") {
            Stop-Script
        }
        elseif ($k -eq "H") {
            Invoke-HelpAction
            continue
        }
        elseif ($k -eq "D") {
            Invoke-DnsScanAction
            continue
        }
        elseif ($k -eq "G") {
            Invoke-PathScanAction
            continue
        }
        elseif ($k -eq "E") {
            Invoke-ExtraViewAction
            continue
        }
        elseif ($k -eq "U") {
            Invoke-UpdateAction
            continue
        }
        elseif ($k -eq "P") {
            Invoke-ProxyMenuAction
            continue
        }
        elseif ($k -eq "S") {
            Invoke-SettingsAction
            continue
        }

        elseif ($k -eq "R") {
            Save-ScanReport
            continue
        }

        # Обработка Enter
        if ($k -eq "Enter") {
            if ($script:ScanPhase -ne "Idle") {
                Write-DebugLog "Ignore Enter while ScanPhase=$($script:ScanPhase)" "INFO"
                continue
            }
            Invoke-ScanAction
            continue
        }
}
}

Initialize-AppState
if (-not $script:BatchMode) {
    Start-MainLoop
}
