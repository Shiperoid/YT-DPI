#!/usr/bin/env bash
# Smoke: синтаксис YT-DPI.sh + офлайн-фикстуры (вердикты, targets parser).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$root/YT-DPI.sh"
[[ -f "$target" ]] || { echo "Missing $target" >&2; exit 1; }

bash -n "$target"
echo "YT-DPI.sh bash -n: OK"

# Подключаем функции без TUI.
export YT_DPI_LIB_ONLY=1
# shellcheck disable=SC1090
source "$target"

fail=0
assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label — got '$got', want '$want'" >&2
        fail=1
    else
        echo "OK: $label"
    fi
}

# --- set_verdict_dual_tls ---
assert_eq "$(set_verdict_dual_tls OK OK)" "AVAILABLE|G" "both OK"
assert_eq "$(set_verdict_dual_tls OK DRP)" "THROTTLED|Y" "OK+DRP"
assert_eq "$(set_verdict_dual_tls RST OK)" "THROTTLED|Y" "RST+OK"
assert_eq "$(set_verdict_dual_tls RST DRP)" "DPI RESET|R" "RST+DRP"
assert_eq "$(set_verdict_dual_tls DRP DRP)" "DPI BLOCK|Y" "DRP+DRP"
assert_eq "$(set_verdict_dual_tls N/A OK)" "AVAILABLE|G" "N/A+OK"
assert_eq "$(set_verdict_dual_tls FAIL FAIL)" "IP BLOCK|R" "FAIL+FAIL"

# --- parse_targets_lines ---
parsed=$(printf '%s\n' \
    '# comment' \
    '' \
    'youtube.com' \
    'nodot' \
    '  music.youtube.com  ' \
    '# googlevideo.com' \
    | parse_targets_lines)
want_parsed=$'youtube.com\nmusic.youtube.com'
assert_eq "$parsed" "$want_parsed" "parse_targets_lines filters"

if (( fail )); then
    echo "smoke-yt-dpi-sh: FAILED" >&2
    exit 1
fi
echo "YT-DPI.sh offline fixtures: OK"
