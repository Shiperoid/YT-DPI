#!/bin/sh
# Bootstrap: запускаем скрипт в bash, включая окружения Entware.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH##*/}" = "sh" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    elif [ -x /opt/bin/bash ]; then
        exec /opt/bin/bash "$0" "$@"
    elif [ -x /opt/bin/env ] && /opt/bin/env bash -c 'exit 0' >/dev/null 2>&1; then
        exec /opt/bin/env bash "$0" "$@"
    fi
    echo "Ошибка: bash не найден. Установите bash (для Entware обычно /opt/bin/bash)." >&2
    exit 1
fi

# YT-DPI.sh — интерактивный терминальный сканер доступности YouTube-доменов.
# Скрипт проверяет HTTP, TLS 1.2 и TLS 1.3, поддерживает прокси и сохраняет отчёт.
# Часть настроек хранится в ~/.config/yt-dpi/config.json (если установлен jq).

# Инициализация TUI: скрываем ввод/курсор и переходим в альтернативный экран (только при TTY).
tui_leave() {
    [ -t 0 ] && stty echo 2>/dev/null || true
    printf '\033[?25h\033[?1049l'
}

tui_enter() {
    printf '\033[?1049h\033[?25l'
    [ -t 0 ] && stty -echo 2>/dev/null || true
}

cleanup() {
    tui_leave
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    exit
}

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

TMP_DIR=""
trap 'cleanup' INT TERM EXIT

tui_enter

for cmd in curl awk; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required." >&2
        exit 1
    fi
done

# Один и тот же curl, что даёт command -v (не только /usr/bin/curl).
CURL_BIN=$(command -v curl)
curl() { "$CURL_BIN" "$@"; }

# Проверка, поддерживает ли текущий curl конкретный флаг.
curl_supports_opt() {
    local opt="$1"
    curl --help all 2>/dev/null | awk -v o="$opt" 'index($0, o) { found=1; exit } END { exit(found?0:1) }'
}

# Не все curl-сборки на роутерах поддерживают одинаковые TLS- и SOCKS-флаги.
CURL_HAS_TLS13=false
CURL_HAS_TLS_MAX=false
CURL_HAS_SOCKS5H=false
curl_supports_opt "--tlsv1.3" && CURL_HAS_TLS13=true
curl_supports_opt "--tls-max" && CURL_HAS_TLS_MAX=true
curl_supports_opt "socks5h://" && CURL_HAS_SOCKS5H=true

proxy_url_for_curl() {
    local px="$1"
    if [[ "$px" == socks5://* ]] && ! $CURL_HAS_SOCKS5H; then
        echo "$px"
        return 0
    fi
    if [[ "$px" == socks5://* ]]; then
        echo "${px/socks5:\/\//socks5h:\/\/}"
        return 0
    fi
    echo "$px"
}

if ! TMP_DIR=$(mktemp -d); then
    echo "Error: mktemp failed (cannot create temp dir)." >&2
    exit 1
fi

OS_MAC=false
if [[ "$OSTYPE" == "darwin"* ]]; then OS_MAC=true; fi

# Опрос клавиш в главном меню (idle) и во время скана.
# Во время скана используем более редкий poll, чтобы не грузить CPU.
READ_TIMEOUT="0.05"
SCAN_READ_TIMEOUT="${YT_DPI_SCAN_READ_TIMEOUT:-0.2}"
DRAIN_READ_TIMEOUT="0.1"
if (( BASH_VERSINFO[0] < 4 )); then READ_TIMEOUT="1"; SCAN_READ_TIMEOUT="1"; DRAIN_READ_TIMEOUT="1"; fi
# Параллельных worker одновременно (каждый — fork + несколько curl). 0 = без лимита (как раньше «все сразу»).
SCAN_MAX_JOBS="${YT_DPI_MAX_JOBS:-}"
if [[ -z "$SCAN_MAX_JOBS" ]] || [[ ! "$SCAN_MAX_JOBS" =~ ^[0-9]+$ ]]; then
    if [[ -n "${MSYSTEM:-}" ]]; then SCAN_MAX_JOBS=6
    elif [[ -d /jffs ]] || [[ -d /overlay ]] || [[ -d /rom ]] || [[ -n "${OPENWRT_RELEASE:-}" ]] || [[ -d /opt/etc/opkg ]]; then
        SCAN_MAX_JOBS=6
    else SCAN_MAX_JOBS=0
    fi
fi

if [[ -n "${MSYSTEM:-}" ]]; then
    READ_TIMEOUT="${YT_DPI_READ_TIMEOUT:-0.2}"
    SCAN_READ_TIMEOUT="${YT_DPI_SCAN_READ_TIMEOUT:-0.3}"
fi

E=$'\033'

SCRIPT_VERSION="2.3.2"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yt-dpi"
CONFIG_FILE="$CONFIG_DIR/config.json"
GEO_CACHE_FILE="$CONFIG_DIR/geo_cache.json"

# Блок runtime-настроек (формат совместим с bat-версией по основным полям).
export IP_PREFERENCE="IPv6"
export TLS_MODE="Auto"
HAS_IPV6=false

PROXY_ENABLED=false
PROXY_TYPE="HTTP"
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""
PROXY_STR=""

PROXY_HISTORY=()

TARGETS=()
CDN=""

# Базовый список целей для сканирования.
BASE_TARGETS=(
    "youtu.be"
    "youtube.com"
    "i.ytimg.com"
    "s.ytimg.com"
    "yt3.ggpht.com"
    "yt4.ggpht.com"
    "s.youtube.com"
    "m.youtube.com"
    "googleapis.com"
    "tv.youtube.com"
    "googlevideo.com"
    "www.youtube.com"
    "play.google.com"
    "youtubekids.com"
    "video.google.com"
    "music.youtube.com"
    "accounts.google.com"
    "clients6.google.com"
    "studio.youtube.com"
    "manifest.googlevideo.com"
    "youtubei.googleapis.com"
    "www.youtube-nocookie.com"
    "signaler-pa.youtube.com"
    "redirector.googlevideo.com"
    "youtubeembeddedplayer.googleapis.com"
)

W_DOM=38; W_IP=22; W_HTTP=6; W_T12=8; W_T13=8; W_LAT=6; W_VER=30
X_DOM=2
X_IP=$((X_DOM + W_DOM + 1))
X_HTTP=$((X_IP + W_IP + 1))
X_T12=$((X_HTTP + W_HTTP + 1))
X_T13=$((X_T12 + W_T12 + 1))
X_LAT=$((X_T13 + W_T13 + 1))
X_VER=$((X_LAT + W_LAT + 1))
C_BLK="${E}[40m"; C_RED="${E}[31m"; C_GRN="${E}[32m"; C_YEL="${E}[33m"
C_MAG="${E}[35m"; C_CYA="${E}[36m"; C_WHT="${E}[97m"; C_GRY="${E}[90m"; C_RST="${E}[0m"

NAV_STR="[ READY ] [ENTER] SCAN | [S] SETTINGS | [P] PROXY | [T] TEST | [R] REPORT | [H] HELP | [Q] QUIT"
NAV_SCAN="[ BUSY ] SCANNING IN PROGRESS... PRESS [Q] TO ABORT"
NAV_ABORT="[ ABORTED ] SCAN STOPPED. [ENTER] SCAN | [S] SETTINGS | [P] PROXY | [T] TEST | [R] REPORT | [H] HELP | [Q] QUIT"
NAV_DONE="[ SUCCESS ] SCAN FINISHED. [ENTER] SCAN | [S] SETTINGS | [P] PROXY | [T] TEST | [R] REPORT | [H] HELP | [Q] QUIT"

FRAME_BUFFER=""
# Запись строки в буфер кадра (без немедленной отправки в терминал).
out_str() {
    local x=$1 y=$2 w=$3 text=$4 color=$5
    local padded
    printf -v padded "%-${w}s" "$text"
    FRAME_BUFFER+="${E}[${y};${x}H${color}${padded}${C_RST}"
}
flush_buffer() { printf "%b" "$FRAME_BUFFER"; FRAME_BUFFER=""; }

# Проверка доступности jq (нужен только для работы с JSON-конфигом).
have_jq() { command -v jq &>/dev/null; }

# Сохранение настроек в JSON-конфиг.
config_save() {
    have_jq || return 0
    mkdir -p "$CONFIG_DIR" || return 1
    local hist_json
    hist_json=$(printf '%s\n' "${PROXY_HISTORY[@]}" | jq -R . 2>/dev/null | jq -s . 2>/dev/null) || hist_json='[]'
    local pe=false
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then pe=true; fi
    local pj port_safe
    port_safe="${PROXY_PORT:-0}"
    [[ "$port_safe" =~ ^[0-9]+$ ]] || port_safe=0
    jq -n \
        --arg IpPreference "$IP_PREFERENCE" \
        --arg TlsMode "$TLS_MODE" \
        --argjson ProxyEnabled "$pe" \
        --arg Type "${PROXY_TYPE:-HTTP}" \
        --arg Host "${PROXY_HOST:-}" \
        --argjson Port "$port_safe" \
        --arg User "${PROXY_USER:-}" \
        --arg Pass "${PROXY_PASS:-}" \
        --argjson History "$hist_json" \
        '{IpPreference:$IpPreference,TlsMode:$TlsMode,Proxy:{Enabled:$ProxyEnabled,Type:$Type,Host:$Host,Port:$Port,User:$User,Pass:$Pass},ProxyHistory:$History}' \
        > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

config_load() {
    have_jq || return 0
    [[ -f "$CONFIG_FILE" ]] || return 0
    IP_PREFERENCE=$(jq -r '.IpPreference // "IPv6"' "$CONFIG_FILE")
    TLS_MODE=$(jq -r '.TlsMode // "Auto"' "$CONFIG_FILE")
    PROXY_HISTORY=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && PROXY_HISTORY+=("$line")
    done < <(jq -r '.ProxyHistory[]? // empty' "$CONFIG_FILE" 2>/dev/null)

    local en type host port user pass
    en=$(jq -r '.Proxy.Enabled // false' "$CONFIG_FILE")
    type=$(jq -r '.Proxy.Type // "HTTP"' "$CONFIG_FILE")
    host=$(jq -r '.Proxy.Host // ""' "$CONFIG_FILE")
    port=$(jq -r '.Proxy.Port // 0' "$CONFIG_FILE")
    user=$(jq -r '.Proxy.User // ""' "$CONFIG_FILE")
    pass=$(jq -r '.Proxy.Pass // ""' "$CONFIG_FILE")

    PROXY_ENABLED=false
    PROXY_TYPE="HTTP"; PROXY_HOST=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""; PROXY_STR=""
    if [[ "$en" == "true" ]] && [[ -n "$host" ]] && [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then
        PROXY_ENABLED=true
        PROXY_TYPE=$(echo "$type" | tr 'a-z' 'A-Z')
        PROXY_HOST="$host"
        PROXY_PORT="$port"
        PROXY_USER="$user"
        PROXY_PASS="$pass"
        local t_lower userpass_str=""
        t_lower=$(echo "$PROXY_TYPE" | tr 'A-Z' 'a-z')
        if [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]]; then userpass_str="${PROXY_USER}:${PROXY_PASS}@"; fi
        PROXY_STR="${t_lower}://${userpass_str}${PROXY_HOST}:${PROXY_PORT}"
        PROXY_STR=$(proxy_url_for_curl "$PROXY_STR")
    fi
}

detect_ipv6() {
    HAS_IPV6=false
    local has_route=false

    # Шаг 1: проверяем, что у системы есть default IPv6 route.
    if command -v ip &>/dev/null; then
        if ip -6 route show default 2>/dev/null | awk 'NF { found=1 } END { exit(found?0:1) }'; then
            has_route=true
        fi
    elif $OS_MAC; then
        if netstat -rn -f inet6 2>/dev/null | awk '$1=="default" || $1=="::/0" { found=1 } END { exit(found?0:1) }'; then
            has_route=true
        fi
    elif command -v route &>/dev/null; then
        if route -n -A inet6 2>/dev/null | awk '$1=="::/0" || $1=="default" { found=1 } END { exit(found?0:1) }'; then
            has_route=true
        fi
    fi

    if ! $has_route; then
        return
    fi

    # Шаг 2: исходящая IPv6-связность (несколько проб: блок только HTTPS к Google ≠ отсутствие IPv6).
    local ping_ok=false
    if command -v ping6 &>/dev/null; then
        if $OS_MAC; then
            # На Darwin не полагаемся на флаги таймаута (-W различается по версиям).
            ping6 -c 1 2001:4860:4860::8888 &>/dev/null && ping_ok=true
        else
            ping6 -c 1 -W 1 2001:4860:4860::8888 &>/dev/null && ping_ok=true
            if ! $ping_ok; then ping6 -c 1 -w 1 2001:4860:4860::8888 &>/dev/null && ping_ok=true; fi
        fi
    fi
    if $ping_ok; then HAS_IPV6=true; return; fi

    local curl_ep
    for curl_ep in "https://www.cloudflare.com" "https://ipv6.google.com"; do
        if curl -6 -s -m 2 -I "$curl_ep" -o /dev/null 2>/dev/null; then
            HAS_IPV6=true
            return
        fi
    done
}

# BaseTargets без manifest: узел вида manifest / rN.* задаёт только CDN после redirector (локальный CDN-шард).
rebuild_targets() {
    local -a raw=()
    local x
    for x in "${BASE_TARGETS[@]}"; do raw+=("$x"); done
    [[ -n "${CDN:-}" ]] && raw+=("$CDN")
    TARGETS=()
    while IFS= read -r x; do
        TARGETS+=("$x")
    done < <(printf '%s\n' "${raw[@]}" | awk '!seen[$0]++' | awk '{ print length"\t"$0 }' | sort -n | cut -f2-)
}

# Тики .NET совместимо с geo_cache из YT-DPI.ps1 для расчёта TTL.
_geo_ticks_now_utc() {
    local sec
    sec=$(date -u +%s 2>/dev/null) || sec=$(date +%s)
    echo $(( (sec + 62135596800) * 10000000 ))
}

geo_proxy_key() {
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then
        echo "${PROXY_TYPE}|${PROXY_HOST}:${PROXY_PORT}"
    else
        echo "direct"
    fi
}

# Нормализация ISP как в PS1 Get-NetworkInfo.
_strip_isp_suffix() {
    if command -v perl &>/dev/null; then
        perl -pe 's/\s+(LLC|Inc\.?|Ltd\.?|sp\. z o\.o\.|CJSC|OJSC|PJSC|PAO|ZAO|OOO|JSC|Private Enterprise|Group|Corporation|Ltd|Limited)\b//gi'
    else
        sed -E 's/[[:space:]]*(LLC|Inc\.?|Ltd\.?|sp\. z o\.o\.|CJSC|OJSC|PJSC|PAO|ZAO|OOO|JSC|Private Enterprise|Group|Corporation|Ltd|Limited)//g'
    fi
}

_geo_cache_hours_age() {
    local cached_ticks now_ticks dt
    cached_ticks=$(jq -r '.TimestampTicks // 0 | tonumber' "$GEO_CACHE_FILE" 2>/dev/null) || return 99
    now_ticks=$(_geo_ticks_now_utc)
    dt=$(( now_ticks > cached_ticks ? now_ticks - cached_ticks : 0 ))
    awk -v d="$dt" 'BEGIN { printf "%.4f\n", d / 36000000000000 }'
}

load_geo_cache() {
    local want pk cached_key age
    ! have_jq && return 1
    [[ -f "$GEO_CACHE_FILE" ]] || return 1
    want=$(geo_proxy_key)
    cached_key=$(jq -r '.ProxyKey // ""' "$GEO_CACHE_FILE" 2>/dev/null)
    [[ -n "$cached_key" ]] && [[ "$cached_key" == "$want" ]] || return 1
    age=$(_geo_cache_hours_age)
    awk -v a="$age" 'BEGIN { if (a+0 >= 24) exit 1; exit 0 }' || return 1
    ISP=$(jq -r '.ISP // empty' "$GEO_CACHE_FILE" 2>/dev/null)
    LOC=$(jq -r '.LOC // empty' "$GEO_CACHE_FILE" 2>/dev/null)
    [[ -n "$ISP" && -n "$LOC" ]]
}

save_geo_cache() {
    local isp="$1" loc="$2"
    ! have_jq && return 0
    mkdir -p "$CONFIG_DIR" || return 1
    local ticks pk
    ticks=$(_geo_ticks_now_utc)
    pk=$(geo_proxy_key)
    jq -n \
        --arg ISP "$isp" \
        --arg LOC "$loc" \
        --arg ProxyKey "$pk" \
        --arg ScriptVersion "$SCRIPT_VERSION" \
        --argjson TimestampTicks "$ticks" \
        '{ISP:$ISP,LOC:$LOC,ProxyKey:$ProxyKey,TimestampTicks:$TimestampTicks,ScriptVersion:$ScriptVersion}' \
        >"${GEO_CACHE_FILE}.tmp" && mv "${GEO_CACHE_FILE}.tmp" "$GEO_CACHE_FILE"
}

# Берём первое поле после «nameserver» (IPv4 / IPv6 / stub 127.0.0.53 / имя хоста).
_dns_from_resolv_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    awk '/^nameserver[[:space:]]+/ { print $2; exit }' "$f" 2>/dev/null
}

detect_local_dns() {
    DNS="UNKNOWN"
    local dn

    # macOS: первый nameserver из scutil (не только [0], строка «nameserver[N]»).
    if $OS_MAC && command -v scutil &>/dev/null; then
        dn=$(scutil --dns 2>/dev/null | awk -F': *' '/nameserver\[[0-9]+\]/{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 != "") { print $2; exit } }')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi

    # systemd-resolved: реальные апстримы (предпочтительнее stub в /etc/resolv.conf).
    if command -v resolvectl &>/dev/null; then
        dn=$(resolvectl status 2>/dev/null | awk '
            /^[[:space:]]*Current DNS Server:/ {
                sub(/^[[:space:]]*Current DNS Server:[[:space:]]*/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if ($0 != "") { print $0; exit }
            }
        ')
        [[ -z "$dn" ]] && dn=$(resolvectl status 2>/dev/null | awk '
            /^[[:space:]]*DNS Servers:/ {
                sub(/^[[:space:]]*DNS Servers:[[:space:]]*/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if ($1 != "") { print $1; exit }
            }
        ')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi

    # NetworkManager.
    if command -v nmcli &>/dev/null; then
        dn=$(nmcli dev show 2>/dev/null | awk -F': +' '/^IP4\.DNS/ { print $2; exit }')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi

    # systemd-resolved: фактический resolv.conf (не только IPv4).
    dn=$(_dns_from_resolv_file /run/systemd/resolve/resolv.conf)
    [[ -n "$dn" ]] && DNS="$dn" && return

    # OpenWrt / UCI.
    if command -v uci &>/dev/null; then
        dn=$(uci -q get network.wan.dns 2>/dev/null | awk '{ print $1; exit }')
        [[ -z "$dn" ]] && dn=$(uci -q get network.@dnsmasq[0].server 2>/dev/null | awk '{ print $1; exit }')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi

    # Обычный resolv.conf (в т.ч. WSL и stub 127.0.0.53).
    dn=$(_dns_from_resolv_file /etc/resolv.conf)
    [[ -n "$dn" ]] && DNS="$dn" && return

    # Android / Termux.
    if command -v getprop &>/dev/null; then
        dn=$(getprop net.dns1 2>/dev/null | tr -d '\r')
        [[ -z "$dn" ]] && dn=$(getprop dhcp.wlan0.dns1 2>/dev/null | tr -d '\r')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi

    # Windows (Git Bash / MSYS / Cygwin): ipconfig.exe.
    local ipcfg=""
    if [[ -n "${SYSTEMROOT:-}" && -x "${SYSTEMROOT}/System32/ipconfig.exe" ]]; then
        ipcfg="${SYSTEMROOT}/System32/ipconfig.exe"
    elif [[ -n "${WINDIR:-}" && -x "${WINDIR}/System32/ipconfig.exe" ]]; then
        ipcfg="${WINDIR}/System32/ipconfig.exe"
    elif [[ -x "/c/Windows/System32/ipconfig.exe" ]]; then
        ipcfg="/c/Windows/System32/ipconfig.exe"
    fi
    if [[ -n "$ipcfg" ]]; then
        dn=$(MSYS2_ARG_CONV_EXCL='*' "$ipcfg" /all 2>/dev/null | tr -d '\r' | LC_ALL=C awk '
            function low(s) { return tolower(s) }
            {
                if (low($0) ~ /dns[[:space:]-]*servers?/) {
                    blk = 1
                    if (match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
                        d = substr($0, RSTART, RLENGTH)
                        if (!(d ~ /^169\.254\./ || d ~ /^127\./)) { print d; exit }
                    }
                    next
                }
            }
            blk && /^[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}/ {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                d = $1
                if (!(d ~ /^169\.254\./ || d ~ /^127\./)) { print d; exit }
            }
            blk && NF && $0 !~ /^[[:space:]]/ { blk = 0 }
        ')
        [[ -n "$dn" ]] && DNS="$dn" && return
    fi
}

# CDN как в PS1: только redirector report_mapping, разбор r1.<short> vs полный *.googlevideo.com.
resolve_cdn_from_redirector() {
    CDN="manifest.googlevideo.com"
    local curl_px=() rnd cdn_raw cdn_short
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then curl_px=( -x "$PROXY_STR" ); fi
    rnd=$(awk 'BEGIN { srand(); print int(1048576 * rand()) }')
    cdn_raw=$(curl -s -m 3 -A "curl/7.88.1" "${curl_px[@]}" "http://redirector.googlevideo.com/report_mapping?di=no&nocache=$rnd" 2>/dev/null) || true
    [[ -z "$cdn_raw" ]] && return

    if [[ "$cdn_raw" =~ =\>[[:space:]]+([A-Za-z0-9-]+) ]]; then
        cdn_short="${BASH_REMATCH[1]}"
    else
        cdn_short=""
    fi
    if [[ -n "$cdn_short" && "$cdn_short" != "r1" ]]; then
        CDN="r1.${cdn_short}.googlevideo.com"
        return
    fi
    if [[ "$cdn_raw" =~ =\>[[:space:]]*([A-Za-z0-9.-]+\.googlevideo\.com) ]]; then
        CDN="${BASH_REMATCH[1]}"
    fi
}

# Цепочка GEO-провайдеров как в Get-NetworkInfo (PS1); нужен jq.
geo_fetch_from_providers() {
    local curl_px=() raw url
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then curl_px=( -x "$PROXY_STR" ); fi

    # ip-api.com
    url="https://ip-api.com/json/?fields=status,countryCode,city,isp"
    raw=$(curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "$url" 2>/dev/null) || raw=""
    if echo "$raw" | jq -e '.status == "success" and .isp' &>/dev/null; then
        local isp loc
        isp=$(echo "$raw" | jq -r '.isp // empty')
        loc=$(echo "$raw" | jq -r '[(.city // ""), (.countryCode // "")] | join(", ")')
        if [[ -n "$isp" && -n "$loc" ]]; then
            echo "$isp"; echo "$loc"; return 0
        fi
    fi

    # ifconfig.co
    url="https://ifconfig.co/json"
    raw=$(curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "$url" 2>/dev/null) || raw=""
    if echo "$raw" | jq -e '.org and .country' &>/dev/null; then
        local isp loc
        isp=$(echo "$raw" | jq -r '.org // empty')
        loc=$(echo "$raw" | jq -r '[(.city // ""), (.country // "")] | join(", ")' 2>/dev/null)
        if [[ -n "$isp" && -n "$loc" ]]; then echo "$isp"; echo "$loc"; return 0; fi
    fi

    # ipapi.co
    url="https://ipapi.co/json/"
    raw=$(curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "$url" 2>/dev/null) || raw=""
    if echo "$raw" | jq -e '(.error | not) and .org and .country_code' &>/dev/null; then
        local isp loc
        isp=$(echo "$raw" | jq -r '.org // empty')
        loc=$(echo "$raw" | jq -r '[(.city // ""), (.country_code // "")] | join(", ")' 2>/dev/null)
        if [[ -n "$isp" && -n "$loc" ]]; then echo "$isp"; echo "$loc"; return 0; fi
    fi

    # ipwhois.app
    url="https://ipwhois.app/json/"
    raw=$(curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "$url" 2>/dev/null) || raw=""
    if echo "$raw" | jq -e '.success == true and .isp' &>/dev/null; then
        local isp loc
        isp=$(echo "$raw" | jq -r '.isp // empty')
        loc=$(echo "$raw" | jq -r '[(.city // ""), (.country_code // "")] | join(", ")' 2>/dev/null)
        if [[ -n "$isp" && -n "$loc" ]]; then echo "$isp"; echo "$loc"; return 0; fi
    fi

    # ipinfo.io
    url="https://ipinfo.io/json"
    raw=$(curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "$url" 2>/dev/null) || raw=""
    if echo "$raw" | jq -e '(.error | not) and .org and .country' &>/dev/null; then
        local isp loc
        isp=$(echo "$raw" | jq -r '(.org // "") | split(" ") | .[0:2] | join(" ")' 2>/dev/null)
        loc=$(echo "$raw" | jq -r '[(.city // ""), (.country // "")] | join(", ")' 2>/dev/null)
        if [[ -n "$isp" && -n "$loc" ]]; then echo "$isp"; echo "$loc"; return 0; fi
    fi

    return 1
}

proxy_history_add() {
    local entry=""
    if [[ "${PROXY_ENABLED}" != true ]] && [[ "${PROXY_ENABLED}" != "1" ]]; then return 0; fi
    entry="${PROXY_TYPE}://"
    if [[ -n "$PROXY_USER" ]]; then entry+="$PROXY_USER:*****@"; fi
    entry+="$PROXY_HOST:$PROXY_PORT"
    local i new_hist=()
    new_hist+=("$entry")
    for (( i=0; i<${#PROXY_HISTORY[@]}; i++ )); do
        [[ "${PROXY_HISTORY[$i]}" == "$entry" ]] && continue
        new_hist+=("${PROXY_HISTORY[$i]}")
        (( ${#new_hist[@]} >= 5 )) && break
    done
    PROXY_HISTORY=("${new_hist[@]}")
    config_save
}

# Получение сетевого контекста для верхней панели (аналог YT-DPI.ps1 Get-NetworkInfo).
get_network_info() {
    detect_local_dns

    resolve_cdn_from_redirector

    ISP="Detecting..."
    LOC="Please wait"

    local curl_px=() geo_ok=false
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then curl_px=( -x "$PROXY_STR" ); fi

    local -a _gl=()
    if load_geo_cache; then
        geo_ok=true
    elif have_jq; then
        local _gf="$TMP_DIR/gf.$$"
        if geo_fetch_from_providers >"$_gf" 2>/dev/null && [[ -s "$_gf" ]]; then
            _gl=()
            while IFS= read -r line; do _gl+=("$line"); done < "$_gf"
        fi
        rm -f "$_gf"
        if [[ ${#_gl[@]} -ge 2 && -n "${_gl[0]}" && -n "${_gl[1]}" ]]; then
            ISP=$(printf '%s' "${_gl[0]}" | _strip_isp_suffix | tr -d '\r')
            LOC=$(printf '%s' "${_gl[1]}" | tr -d '\r')
            save_geo_cache "$ISP" "$LOC"
            geo_ok=true
        fi
    fi

    if ! $geo_ok; then
        ISP="UNKNOWN"
        LOC="UNKNOWN"
        local geo_tmp geo_raw
        geo_tmp="$TMP_DIR/yt_dpi_geo.$$"
        curl -s -A "curl/7.88.1" -m 2 "${curl_px[@]}" "http://ip-api.com/line/?fields=status,countryCode,city,isp" >"$geo_tmp" 2>/dev/null || true
        geo_raw=$(cat "$geo_tmp" 2>/dev/null)
        rm -f "$geo_tmp"
        if [[ "$(echo "$geo_raw" | sed -n '1p' | tr -d '\r\n')" == "success" ]]; then
            LOC="$(echo "$geo_raw" | sed -n '3p' | tr -d '\r\n'), $(echo "$geo_raw" | sed -n '2p' | tr -d '\r\n')"
            ISP=$(echo "$geo_raw" | sed -n '4p' | tr -d '\r\n' | _strip_isp_suffix)
            [[ -n "$ISP" && -n "$LOC" ]] && have_jq && save_geo_cache "$ISP" "$LOC"
        else
            ISP="Geo unavailable"
            LOC="Use --fast-mode"
        fi
    fi

    ((${#ISP} > 30)) && ISP="${ISP:0:27}..."

    detect_ipv6
}

draw_ui() {
    clear; FRAME_BUFFER=""
    out_str 1 1 0 ' ██╗   ██╗████████╗    ██████╗ ██████╗ ██╗' "$C_GRN"
    out_str 1 2 0 ' ╚██╗ ██╔╝╚══██╔══╝    ██╔══██╗██╔══██╗██║' "$C_GRN"
    out_str 1 3 0 '  ╚████╔╝    ██║ █████╗██║  ██║██████╔╝██║' "$C_GRN"
    out_str 1 4 0 '   ╚██╔╝     ██║ ╚════╝██║  ██║██╔═══╝ ██║' "$C_GRN"
    out_str 1 5 0 '    ██║      ██║       ██████║ ██║     ██║' "$C_GRN"
    out_str 1 6 0 '    ╚═╝      ╚═╝       ╚═════╝ ╚═╝     ╚═╝' "$C_GRN"

    out_str 45 1 0 '██████╗    ██████╗ ' "$C_GRY"
    out_str 45 2 0 '╚════██╗   ╚════██╗' "$C_GRY"
    out_str 45 3 0 ' █████╔╝    █████╔╝' "$C_GRY"
    out_str 45 4 0 '██╔═══╝    ██╔═══╝' "$C_GRY"
    out_str 45 5 0 '███████╗██╗███████╗' "$C_GRY"
    out_str 45 6 0 '╚══════╝╚═╝╚══════╝' "$C_GRY"

    out_str 65 1 0 "> SYS STATUS: [ ONLINE ]" "$C_GRN"
    out_str 65 2 50 "> ENGINE: Barebuh Pro v2.3.7" "$C_RED"
    out_str 65 3 50 "> LOCAL DNS: $DNS" "$C_CYA"
    out_str 65 4 50 "> CDN NODE: $CDN" "$C_YEL"
    out_str 65 5 0 "> AUTHOR: github.com/Shiperoid" "$C_GRN"

    local disp_isp="$ISP" disp_loc="$LOC"
    ((${#disp_isp} > 35)) && disp_isp="${disp_isp:0:32}..."
    ((${#disp_loc} > 30)) && disp_loc="${disp_loc:0:27}..."
    local isp_str="> ISP / LOC: $disp_isp ($disp_loc)"
    local isp_pad="${isp_str}"
    ((${#isp_pad} < 80)) && isp_pad=$(printf '%-80s' "$isp_str") || isp_pad="${isp_str:0:80}"
    out_str 65 6 80 "$isp_pad" "$C_MAG"

    local px_stat
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then
        px_stat="> PROXY: $PROXY_TYPE $PROXY_HOST:$PROXY_PORT Connected"
    else
        px_stat="> PROXY: [ OFF ]"
    fi
    local px_pad="$px_stat"
    ((${#px_pad} < 58)) && px_pad=$(printf '%-58s' "$px_stat") || px_pad="${px_stat:0:58}"
    out_str 65 7 58 "$px_pad" "$C_YEL"

    out_str 65 8 0 "> TG: t.me/YT_DPI | VERSION: $SCRIPT_VERSION" "$C_GRN"

    local l="========================================================================================================================="
    out_str 0 9 0 "$l" "$C_CYA"
    out_str $X_DOM 10 0 "TARGET DOMAIN" "$C_WHT"
    out_str $X_IP  10 0 "IP ADDRESS" "$C_WHT"
    out_str $X_HTTP 10 0 "HTTP" "$C_WHT"
    out_str $X_T12 10 0 "TLS 1.2" "$C_WHT"
    out_str $X_T13 10 0 "TLS 1.3" "$C_WHT"
    out_str $X_LAT 10 0 "LAT" "$C_WHT"
    out_str $X_VER 10 0 "RESULT" "$C_WHT"
    out_str 0 11 0 "$l" "$C_CYA"

    for i in "${!TARGETS[@]}"; do
        local row=$((12 + i))
        out_str $X_DOM $row $W_DOM "${TARGETS[$i]}" "$C_GRY"
        out_str $X_IP   $row $W_IP "---.---.---.---" "$C_GRY"
        out_str $X_HTTP $row $W_HTTP "--" "$C_GRY"
        out_str $X_T12  $row $W_T12 "--" "$C_GRY"
        out_str $X_T13  $row $W_T13 "--" "$C_GRY"
        out_str $X_LAT  $row $W_LAT "----" "$C_GRY"
        out_str $X_VER  $row $W_VER "IDLE" "$C_GRY"
    done
    out_str 0 $((12 + ${#TARGETS[@]})) 0 "$l" "$C_CYA"
    flush_buffer
}

show_help() {
    tui_leave
    clear
    echo -e "${C_CYA}=== YT-DPI v${SCRIPT_VERSION} : GUIDE ===${C_RST}"
    echo -e "\n${C_YEL}[ STATUS CODES ]${C_RST}"
    echo -e "  ${C_GRN}OK   - Connection successful.${C_RST}"
    echo -e "  ${C_RED}RST  - Connection Reset. DPI injected a TCP RST packet.${C_RST}"
    echo -e "  ${C_RED}DRP  - Connection Dropped (Blackholed/Timeout).${C_RST}"
    echo -e "  ${C_GRY}N/A  - Not Available (e.g. lack of TLS 1.3 support).${C_RST}"
    echo -e "  ${C_RED}FAIL - Connection failed or general error.${C_RST}"

    echo -e "\n${C_YEL}[ RESULT ]${C_RST}"
    echo -e "  ${C_GRN}AVAILABLE     - TLS passed. Domain is fully accessible.${C_RST}"
    echo -e "  ${C_YEL}DPI BLOCK     - HTTP works, but TLS is blocked/dropped.${C_RST}"
    echo -e "  ${C_YEL}THROTTLED     - HTTP works, but one TLS version is blocked.${C_RST}"
    echo -e "  ${C_RED}IP  BLOCK     - Both HTTP and TLS are unreachable.${C_RST}"
    echo -e "  ${C_RED}ROUTING ERROR - Network issues, proxy failure, bad routing.${C_RST}"

    echo -ne "\n${C_CYA}PRESS ANY KEY TO RETURN...${C_RST}"
    read -r -n 1 -s
    tui_enter
}

# Меню общих настроек сканера (IP preference и TLS mode).
show_settings_menu() {
    tui_leave
    clear
    echo -e "${C_CYA}=== SETTINGS (как в YT-DPI.bat, упрощённо) ===${C_RST}"
    echo -e "  IpPreference: ${C_YEL}$IP_PREFERENCE${C_RST}   TlsMode: ${C_YEL}$TLS_MODE${C_RST}"
    echo -e "  IPv6 detected: ${C_YEL}$HAS_IPV6${C_RST}"
    echo -e "\n${C_CYA}Выберите:${C_RST}"
    echo -e "  ${C_GRY}1${C_RST} — IpPreference: IPv6"
    echo -e "  ${C_GRY}2${C_RST} — IpPreference: IPv4"
    echo -e "  ${C_GRY}3${C_RST} — TlsMode: Auto"
    echo -e "  ${C_GRY}4${C_RST} — TlsMode: TLS12"
    echo -e "  ${C_GRY}5${C_RST} — TlsMode: TLS13"
    echo -e "  ${C_GRY}Enter${C_RST} — назад"
    echo -ne "\n${C_YEL}> ${C_RST}"
    local c
    read -r c
    case "$c" in
        1) IP_PREFERENCE="IPv6" ;;
        2) IP_PREFERENCE="IPv4" ;;
        3) TLS_MODE="Auto" ;;
        4) TLS_MODE="TLS12" ;;
        5) TLS_MODE="TLS13" ;;
        *) tui_enter; return 0 ;;
    esac
    config_save
    echo -e "\n${C_GRN}[OK] Сохранено.${C_RST}"
    sleep 1
    tui_enter
}

# Применение записи из истории прокси.
# Формат записи: TYPE://[user:*****@]host:port
apply_proxy_history_entry() {
    local entry=$1
    [[ -z "$entry" ]] && return 1
    local proto="" user="" host="" port=""
    if [[ "$entry" =~ ^([a-zA-Z]+)://(?:([^:]+):\*\*\*\*\*@)?([^:]+):([0-9]+)$ ]]; then
        proto="${BASH_REMATCH[1]}"
        user="${BASH_REMATCH[2]}"
        host="${BASH_REMATCH[3]}"
        port="${BASH_REMATCH[4]}"
    else
        return 1
    fi
    PROXY_TYPE=$(echo "$proto" | tr 'a-z' 'A-Z')
    PROXY_HOST="$host"
    PROXY_PORT="$port"
    PROXY_USER="${user:-}"
    PROXY_PASS=""
    if [[ -n "$PROXY_USER" ]]; then
        [ -t 0 ] && stty echo 2>/dev/null || true
        echo -ne "\n${C_YEL}Пароль для $PROXY_USER@${PROXY_HOST}:${PROXY_PORT}: ${C_RST}"
        read -r PROXY_PASS
        [ -t 0 ] && stty -echo 2>/dev/null || true
    fi
    local userpass_str="" t_lower
    if [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]]; then userpass_str="${PROXY_USER}:${PROXY_PASS}@"; fi
    t_lower=$(echo "$PROXY_TYPE" | tr 'A-Z' 'a-z')
    PROXY_STR="${t_lower}://${userpass_str}${PROXY_HOST}:${PROXY_PORT}"
    PROXY_ENABLED=true
    PROXY_STR=$(proxy_url_for_curl "$PROXY_STR")
    proxy_history_add
    return 0
}

# Интерактивное меню настройки прокси.
show_proxy_menu() {
    tui_leave
    clear
    echo -e "${C_CYA}=== НАСТРОЙКИ ПРОКСИ (YT-DPI v${SCRIPT_VERSION}) ===${C_RST}"

    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then
        echo -e "  [ СТАТУС ]  ${C_GRN}ВКЛЮЧЕН${C_RST}"
        echo -e "  [ ТИП ]     ${C_YEL}$PROXY_TYPE${C_RST}"
        echo -e "  [ АДРЕС ]   ${C_YEL}$PROXY_HOST:$PROXY_PORT${C_RST}"
        if [ -n "$PROXY_USER" ]; then echo -e "  [ ЛОГИН ]   ${C_YEL}$PROXY_USER${C_RST}"; fi
    else
        echo -e "  [ СТАТУС ]  ${C_GRY}ОТКЛЮЧЕН${C_RST}"
    fi

    if ((${#PROXY_HISTORY[@]} > 0)); then
        echo -e "\n${C_CYA}ИСТОРИЯ (номер для выбора):${C_RST}"
        local hi
        for (( hi=0; hi<${#PROXY_HISTORY[@]}; hi++ )); do
            echo -e "    $((hi+1)). ${PROXY_HISTORY[$hi]}"
        done
        echo -e "    ${C_GRY}0. Очистить историю (CLEAR)${C_RST}"
    fi

    echo -e "\n${C_CYA}Команды:${C_RST} ${C_GRY}TEST${C_RST} — проверить текущий прокси | ${C_GRY}CLEAR${C_RST} — очистить историю"
    echo -e "${C_CYA}Форматы:${C_RST} host:port | socks5://... | http://user:pass@host:port | ${C_GRY}OFF/0${C_RST}"

    echo -ne "\n${C_YEL}> Введите прокси (или номер из истории): ${C_RST}"
    local px_input
    read -r px_input

    px_input=$(echo "$px_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$px_input" ]] && { tui_enter; return 0; }

    shopt -s nocasematch
    if [[ "$px_input" == "TEST" ]]; then
        shopt -u nocasematch
        test_proxy
        return 0
    fi
    if [[ "$px_input" == "CLEAR" ]]; then
        shopt -u nocasematch
        PROXY_HISTORY=()
        config_save
        echo -e "\n${C_GRN}[OK] История очищена.${C_RST}"; sleep 1
        tui_enter
        return 0
    fi
    shopt -u nocasematch

    if [[ "$px_input" =~ ^[0-9]+$ ]]; then
        local n=$px_input
        if (( n == 0 )) && ((${#PROXY_HISTORY[@]} > 0)); then
            PROXY_HISTORY=()
            config_save
            echo -e "\n${C_GRN}[OK] История очищена.${C_RST}"; sleep 1
            tui_enter
            return 0
        fi
        if (( n >= 1 && n <= ${#PROXY_HISTORY[@]} )); then
            if apply_proxy_history_entry "${PROXY_HISTORY[$((n-1))]}"; then
                echo -e "\n${C_GRN}[OK] Прокси из истории применён.${C_RST}"; sleep 1
            fi
            tui_enter
            return 0
        fi
        if (( n >= 1 )); then
            echo -e "\n${C_RED}[x] История прокси пуста или нет записи №${n}.${C_RST}"; sleep 2
            tui_enter
            return 0
        fi
    fi

    if [[ "$px_input" == "0" || "$px_input" == "off" || "$px_input" == "OFF" ]]; then
        PROXY_ENABLED=false
        PROXY_TYPE="HTTP"; PROXY_HOST=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""; PROXY_STR=""
        config_save
        echo -e "\n${C_GRN}[OK] Прокси отключён.${C_RST}"; sleep 1
        tui_enter
        return 0
    fi

    local re="^((http|https|socks5)://)?(([^:]+):([^@]+)@)?([^:/]+|\[[a-fA-F0-9:]+\]):([0-9]{1,5})$"

    shopt -s nocasematch
    if [[ "$px_input" =~ $re ]]; then
        shopt -u nocasematch

        local t="${BASH_REMATCH[2]}" u="${BASH_REMATCH[4]}" pw="${BASH_REMATCH[5]}"
        local h="${BASH_REMATCH[6]}" p="${BASH_REMATCH[7]}"

        if (( p <= 0 || p > 65535 )); then
            echo -e "\n${C_RED}[x] Неверный порт.${C_RST}"; sleep 2
            tui_enter
            return 0
        fi

        local userpass_str=""
        if [[ -n "$u" && -n "$pw" ]]; then userpass_str="${u}:${pw}@"; fi

        if [[ -z "$t" ]]; then
            echo -e "\n${C_GRY}[*] Автоопределение типа...${C_RST}"
            local detected="HTTP"
            echo -ne "  -> SOCKS5... ${C_GRY}"
            if curl -s -m 3 -x "socks5://${userpass_str}${h}:${p}" -I "http://google.com" -o /dev/null; then
                detected="SOCKS5"; echo -e "${C_GRN}OK${C_RST}"
            else
                echo -e "${C_RED}нет${C_RST}"; echo -ne "  -> HTTP... ${C_GRY}"
                if curl -s -m 3 -x "http://${userpass_str}${h}:${p}" -I "http://google.com" -o /dev/null; then
                    detected="HTTP"; echo -e "${C_GRN}OK${C_RST}"
                else
                    echo -e "${C_RED}нет${C_RST}"
                    echo -e "  ${C_GRY}[!] Оставляем HTTP.${C_RST}"
                fi
            fi
            t="$detected"
        fi

        PROXY_ENABLED=true
        PROXY_TYPE=$(echo "$t" | tr 'a-z' 'A-Z')
        PROXY_HOST="$h"; PROXY_PORT="$p"; PROXY_USER="$u"; PROXY_PASS="$pw"

        local t_lower=$(echo "$PROXY_TYPE" | tr 'A-Z' 'a-z')
        PROXY_STR="${t_lower}://${userpass_str}${PROXY_HOST}:${PROXY_PORT}"
        PROXY_STR=$(proxy_url_for_curl "$PROXY_STR")

        proxy_history_add
        echo -e "\n${C_GRN}[OK] Прокси сохранён.${C_RST}"; sleep 1
        tui_enter
    else
        shopt -u nocasematch
        echo -e "\n${C_RED}[x] Неверный формат.${C_RST}"; sleep 2
        tui_enter
    fi
}

# Быстрая проверка текущих прокси-настроек.
test_proxy() {
    tui_leave
    clear
    echo -e "${C_CYA}=== ТЕСТ ПРОКСИ ===${C_RST}"
    if [[ "${PROXY_ENABLED}" != true ]] && [[ "${PROXY_ENABLED}" != "1" ]]; then
        echo -e "${C_RED}Прокси отключён.${C_RST}"; sleep 2
        tui_enter
        return
    fi

    echo -e "${C_YEL}Подключение к google.com:80 через $PROXY_TYPE...${C_RST}"
    local out
    out=$(curl -s -w "\n%{time_connect}" -m 3 -x "$PROXY_STR" -I "http://google.com")
    if [ $? -eq 0 ]; then
        local ms=$(echo "$out" | tail -n1 | awk '{print int($1*1000)}')
        echo -e "${C_GRN}OK за ${ms} мс.${C_RST}"
    else
        echo -e "${C_RED}Ошибка соединения.${C_RST}"
    fi
    echo -ne "\n${C_CYA}Нажмите любую клавишу...${C_RST}"; read -r -n 1 -s
    tui_enter
}

# Резолв адреса цели с учётом IP preference и доступности IPv6.
resolve_target_ip() {
    local target=$1
    local ip=""

    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then
        echo "[ *PROXIED* ]"
        return 0
    fi

    if [[ "$IP_PREFERENCE" == "IPv6" ]] && $HAS_IPV6 && command -v getent &>/dev/null; then
        ip=$(getent ahostsv6 "$target" 2>/dev/null | awk '/STREAM|STREAM tcp/ {print $1; exit}')
        [[ -z "$ip" ]] && ip=$(getent ahostsv6 "$target" 2>/dev/null | awk '{print $1; exit}')
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    fi

    if command -v getent &>/dev/null; then
        ip=$(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
    fi
    # Не брать первый «Address:» — в выводе Windows это часто адрес DNS-сервера (192.168.x.x), а не цель.
    if [ -z "$ip" ] && command -v nslookup &>/dev/null; then
        ip=$(nslookup "$target" 2>/dev/null | awk '
            /^Name:[[:space:]]/ { grab = 1; next }
            grab && /^Address(es)?:[[:space:]]+[0-9]/ {
                for (i = 2; i <= NF; i++)
                    if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
            }
        ')
    fi
    if [ -z "$ip" ]; then
        local ping_out
        if $OS_MAC; then ping_out=$(LC_ALL=C ping -c 1 -t 1 "$target" 2>/dev/null)
        else ping_out=$(LC_ALL=C ping -c 1 -W 1 "$target" 2>/dev/null); fi
        ip=$(printf '%s\n' "$ping_out" | sed -n 's/^PING[^(]*(\([0-9.]\{1,\}\)).*/\1/p' | head -n 1)
        if [ -z "$ip" ]; then
            ip=$(printf '%s\n' "$ping_out" | sed -n 's/^Pinging [[:alnum:].-]* \[\([0-9.]\{1,\}\)\].*/\1/p' | head -n 1)
        fi
    fi

    if [ -z "$ip" ]; then echo ""; return 1; fi
    echo "$ip"
    return 0
}

# Рабочий поток проверки одной цели.
# Формат результата: IP|HTTP|TLS12|TLS13|LAT|VERDICT|COLOR
worker() {
    local target=$1 row=$2
    local ip="" http="FAIL" t12="FAIL" t13="FAIL" lat="0ms" verdict="IP BLOCK" color="$C_RED"

    local curl_px=()
    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then
        local px_url
        px_url=$(proxy_url_for_curl "$PROXY_STR")
        curl_px=( -x "$px_url" )
        ip="[ *PROXIED* ]"
    fi

    local http_out lat_raw rip http_ec
    http_out=$(curl -s -m 2 "${curl_px[@]}" -I "http://$target" -A "curl/7.88.1" -w "\nREMOTE_IP=%{remote_ip}\nTIME_TOTAL=%{time_total}" 2>&1)
    http_ec=$?
    rip=$(printf '%s\n' "$http_out" | sed -n 's/^REMOTE_IP=//p' | tail -n 1 | tr -d '\r\n\t ')
    if [[ "${PROXY_ENABLED}" != true ]] && [[ "${PROXY_ENABLED}" != "1" ]]; then
        if [[ -n "$rip" ]] && [[ "$rip" != "0.0.0.0" ]] && [[ "$rip" != "::" ]]; then
            ip="$rip"
        else
            ip=$(resolve_target_ip "$target") || true
            [[ -z "$ip" ]] && ip="---"
        fi
    fi

    if [ "$http_ec" -eq 0 ]; then
        http="OK"
        lat_raw=$(echo "$http_out" | tr ',' '.' | awk -F= '/^TIME_TOTAL=/{print $2}' | tail -n1 | tr -d '\r')
        if [[ "$lat_raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            lat=$(awk -v t="$lat_raw" 'BEGIN{v=int(t*1000); if(v<1) v=1; print v"ms"}')
        else
            lat="---"
        fi
    else
        if echo "$http_out" | grep -qi "timeout"; then http="DROP"; else http="ERR"; fi
    fi

    if [[ "$TLS_MODE" == "TLS13" ]]; then
        t12="---"
        if ! $CURL_HAS_TLS13; then
            t13="N/A"
        else
            local t13_out
            t13_out=$(LC_ALL=C curl -k -s -m 3 "${curl_px[@]}" -I "https://$target" --tlsv1.3 2>&1)
            if [ $? -eq 0 ]; then t13="OK"
            elif echo "$t13_out" | grep -qiE "unsupported|not supported|unknown option|unrecognized option|built-in"; then t13="N/A"
            elif echo "$t13_out" | grep -qi "reset"; then t13="RST"
            else t13="DRP"
            fi
        fi
    elif [[ "$TLS_MODE" == "TLS12" ]]; then
        t13="---"
        if ! $CURL_HAS_TLS_MAX; then
            t12="N/A"
        else
            local t12_out
            t12_out=$(curl -k -s -m 3 "${curl_px[@]}" -I "https://$target" --tls-max 1.2 2>&1)
            if [ $? -eq 0 ]; then t12="OK"
            elif echo "$t12_out" | grep -qi "reset"; then t12="RST"
            else t12="DRP"
            fi
        fi
    else
        # Auto: обе проверки TLS независимы — параллельно, чтобы не суммировать таймауты.
        local t12_tmp="$TMP_DIR/w.${row}.12" t13_tmp="$TMP_DIR/w.${row}.13" t12_out t13_out ec12 ec13 pid12 pid13
        if $CURL_HAS_TLS_MAX; then
            curl -k -s -m 3 "${curl_px[@]}" -I "https://$target" --tls-max 1.2 >"$t12_tmp" 2>&1 & pid12=$!
        else
            : >"$t12_tmp"
            ec12=2
        fi
        if $CURL_HAS_TLS13; then
            LC_ALL=C curl -k -s -m 3 "${curl_px[@]}" -I "https://$target" --tlsv1.3 >"$t13_tmp" 2>&1 & pid13=$!
        else
            : >"$t13_tmp"
            ec13=2
        fi

        if [[ -n "${pid12:-}" ]]; then wait "$pid12"; ec12=$?; fi
        if [[ -n "${pid13:-}" ]]; then wait "$pid13"; ec13=$?; fi
        t12_out=$(cat "$t12_tmp")
        t13_out=$(cat "$t13_tmp")
        rm -f "$t12_tmp" "$t13_tmp"

        if ! $CURL_HAS_TLS_MAX; then t12="N/A"
        elif [ "$ec12" -eq 0 ]; then t12="OK"
        elif echo "$t12_out" | grep -qi "reset"; then t12="RST"
        else t12="DRP"
        fi
        if ! $CURL_HAS_TLS13; then t13="N/A"
        elif [ "$ec13" -eq 0 ]; then t13="OK"
        elif echo "$t13_out" | grep -qiE "unsupported|not supported|unknown option|unrecognized option|built-in"; then t13="N/A"
        elif echo "$t13_out" | grep -qi "reset"; then t13="RST"
        else t13="DRP"
        fi
    fi

    if [ "$http" == "OK" ]; then
        if [[ "$TLS_MODE" == "TLS12" ]]; then
            if [ "$t12" == "OK" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t12" == "RST" ] || [ "$t12" == "DRP" ]; then verdict="DPI BLOCK"; color="$C_YEL"
            else verdict="DPI BLOCK"; color="$C_YEL"; fi
        elif [[ "$TLS_MODE" == "TLS13" ]]; then
            if [ "$t13" == "OK" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t13" == "N/A" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t13" == "RST" ] || [ "$t13" == "DRP" ]; then verdict="DPI BLOCK"; color="$C_YEL"
            else verdict="DPI BLOCK"; color="$C_YEL"; fi
        else
            if [ "$t12" == "OK" ] && [ "$t13" == "OK" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t12" == "OK" ] && [ "$t13" == "N/A" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t12" == "N/A" ] && [ "$t13" == "OK" ]; then verdict="AVAILABLE"; color="$C_GRN"
            elif [ "$t12" == "OK" ] && { [ "$t13" == "RST" ] || [ "$t13" == "DRP" ]; }; then verdict="THROTTLED"; color="$C_YEL"
            elif [ "$t13" == "OK" ] && { [ "$t12" == "RST" ] || [ "$t12" == "DRP" ]; }; then verdict="THROTTLED"; color="$C_YEL"
            else verdict="DPI BLOCK"; color="$C_YEL"; fi
        fi
    else
        # HTTP не OK -> смотрим RST ошибки
        if { [ "$t12" == "RST" ] || [ "$t13" == "RST" ]; } && [ "$http" == "ERR" ]; then
            verdict="ROUTING ERROR"; color="$C_RED"
        else
            verdict="IP BLOCK"; color="$C_RED"
        fi
    fi

    echo "$ip|$http|$t12|$t13|$lat|$verdict|$color" > "$TMP_DIR/$row.res"
}

ui_state_sig() {
    local tg
    tg=$(printf '%s|' "${TARGETS[@]}")
    printf '%s' "${DNS}|${CDN}|${ISP}|${LOC}|${PROXY_ENABLED}|${PROXY_TYPE}|${PROXY_HOST}|${PROXY_PORT}|${IP_PREFERENCE}|${TLS_MODE}|${HAS_IPV6}|${tg}"
}

config_load

FIRST_RUN=true

while true; do
    if $FIRST_RUN; then
        get_network_info
        rebuild_targets
        draw_ui
        UI_Y=$((12 + ${#TARGETS[@]} + 1))
        out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer
        FIRST_RUN=false
    fi

    read -t $READ_TIMEOUT -n 1 -s key
    READ_STATUS=$?

    # Горячие клавиши: EN и те же физические клавиши под RU (ЙЦУКЕН).
    if [[ "$key" == "q" || "$key" == "Q" || "$key" == "й" || "$key" == "Й" || "$key" == $'\e' ]]; then break
    elif [[ "$key" == "h" || "$key" == "H" || "$key" == "р" || "$key" == "Р" ]]; then show_help; draw_ui; out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer
    elif [[ "$key" == "s" || "$key" == "S" || "$key" == "ы" || "$key" == "Ы" ]]; then show_settings_menu; get_network_info; rebuild_targets; draw_ui; out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer
    elif [[ "$key" == "p" || "$key" == "P" || "$key" == "з" || "$key" == "З" ]]; then show_proxy_menu; get_network_info; rebuild_targets; draw_ui; out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer
    elif [[ "$key" == "t" || "$key" == "T" || "$key" == "е" || "$key" == "Е" ]]; then test_proxy; draw_ui; out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer
    elif [[ "$key" == "r" || "$key" == "R" || "$key" == "к" || "$key" == "К" ]]; then
        out_str 2 $UI_Y 121 "[ WAIT ] SAVING REPORT..." "$C_CYA"; flush_buffer
        LOG="YT-DPI_Report.txt"
        {
            echo "=== YT-DPI REPORT v${SCRIPT_VERSION} ==="
            echo "TIME: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "ISP:  $ISP ($LOC)"
            echo "DNS:  $DNS"
            echo "IpPreference: $IP_PREFERENCE  TlsMode: $TLS_MODE"
            if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then echo "PROXY: $PROXY_TYPE $PROXY_HOST:$PROXY_PORT"; else echo "PROXY: [ OFF ]"; fi
            echo "------------------------------------------------------------------------------------------"
            printf "%-38s %-16s %-6s %-8s %-8s %-6s %s\n" "TARGET DOMAIN" "IP ADDRESS" "HTTP" "TLS 1.2" "TLS 1.3" "LAT" "RESULT"
            echo "------------------------------------------------------------------------------------------"
            for i in "${!TARGETS[@]}"; do
                row=$((12 + i))
                if [ -f "$TMP_DIR/$row.res" ]; then
                    IFS='|' read -r rip http t12 t13 lat verdict color < "$TMP_DIR/$row.res"
                    if [[ "${PROXY_ENABLED}" == true ]] || [[ "${PROXY_ENABLED}" == "1" ]]; then rip="[ PROXIED ]"; fi
                    printf "%-38s %-16s %-6s %-8s %-8s %-6s %s\n" "${TARGETS[$i]}" "$rip" "$http" "$t12" "$t13" "$lat" "$verdict"
                fi
            done
        } > "$LOG"
        out_str 2 $UI_Y 121 "[ SUCCESS ] SAVED: $(pwd)/$LOG" "$C_GRN"; flush_buffer
        sleep 2; out_str 2 $UI_Y 121 "$NAV_STR" "$C_WHT"; flush_buffer

    elif [[ "$key" == $'\n' || "$key" == $'\r' ]] || [[ $READ_STATUS -eq 0 && -z "$key" ]]; then
        old_sig=""
        new_sig=""
        old_sig=$(ui_state_sig)
        out_str 2 $UI_Y 121 "[ WAIT ] REFRESHING NETWORK STATE..." "$C_CYA"; flush_buffer
        get_network_info
        rebuild_targets
        new_sig=$(ui_state_sig)

        if [[ "$new_sig" != "$old_sig" ]]; then
            draw_ui
            UI_Y=$((12 + ${#TARGETS[@]} + 1))
        fi
        out_str 2 $UI_Y 121 "$NAV_SCAN" "$C_YEL"; flush_buffer

        rm -f "$TMP_DIR"/*.res
        JOB_STATE=()
        ACTIVE_JOBS=${#TARGETS[@]}

        export PROXY_ENABLED PROXY_TYPE PROXY_STR IP_PREFERENCE TLS_MODE HAS_IPV6 OS_MAC

        running_jobs=0
        for i in "${!TARGETS[@]}"; do
            row=$((12 + i))
            out_str $X_VER $row $W_VER "PREPARING..." "$C_GRY"
            JOB_STATE[$i]=1
            if (( SCAN_MAX_JOBS > 0 )); then
                while true; do
                    running_jobs=$(jobs -rp 2>/dev/null | wc -l | tr -d ' ')
                    (( running_jobs < SCAN_MAX_JOBS )) && break
                    sleep 0.1
                done
            fi
            worker "${TARGETS[$i]}" "$row" < /dev/null &
            ((running_jobs++))
        done
        flush_buffer

        aborted=false
        while [ $ACTIVE_JOBS -gt 0 ]; do
            read -t $SCAN_READ_TIMEOUT -n 1 -s inkey
            if [[ "$inkey" == "q" || "$inkey" == "Q" || "$inkey" == "й" || "$inkey" == "Й" || "$inkey" == $'\e' ]]; then aborted=true; break; fi

            for i in "${!TARGETS[@]}"; do
                if [ "${JOB_STATE[$i]}" -eq 0 ]; then continue; fi
                row=$((12 + i))

                if [ -f "$TMP_DIR/$row.res" ]; then
                    IFS='|' read -r ip http t12 t13 lat verdict color < "$TMP_DIR/$row.res"

                    out_str $X_IP   $row $W_IP "$ip" "$C_GRY"
                    [ "$http" == "OK" ] && hcol="$C_GRN" || hcol="$C_RED"
                    out_str $X_HTTP $row $W_HTTP "$http" "$hcol"
                    [ "$t12" == "OK" ] && t12col="$C_GRN" || t12col="$C_RED"
                    [[ "$t12" == "---" ]] && t12col="$C_GRY"
                    out_str $X_T12  $row $W_T12 "$t12" "$t12col"
                    if [ "$t13" == "OK" ]; then t13col="$C_GRN"
                    elif [ "$t13" == "N/A" ] || [ "$t13" == "---" ]; then t13col="$C_GRY"
                    else t13col="$C_RED"; fi
                    out_str $X_T13  $row $W_T13 "$t13" "$t13col"
                    out_str $X_LAT  $row $W_LAT "$lat" "$C_CYA"
                    out_str $X_VER  $row $W_VER "$verdict" "$color"

                    JOB_STATE[$i]=0
                    ((ACTIVE_JOBS--))
                fi
            done
            if [[ -n "$FRAME_BUFFER" ]]; then flush_buffer; fi
        done

        if $aborted; then
            kill $(jobs -p) 2>/dev/null
            out_str 2 $UI_Y 121 "$NAV_ABORT" "$C_RED"
        else
            out_str 2 $UI_Y 121 "$NAV_DONE" "$C_GRN"
        fi
        flush_buffer
        while read -t "$DRAIN_READ_TIMEOUT" -n 1 -s; do : ; done
    fi
done
