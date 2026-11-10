#!/bin/sh
# Claude Code status line hook for cc-menubar.
# Claude Code pipes session JSON (including rate_limits.five_hour / seven_day) to this script.
# We save it for the menu bar app and print a short usage line. POSIX sh, no jq needed.
dir="$HOME/.cache/cc-menubar"
mkdir -p "$dir"
json=$(cat)
case "$json" in
  *'"rate_limits"'*)
    printf '%s' "$json" > "$dir/usage.json.tmp" && mv "$dir/usage.json.tmp" "$dir/usage.json" ;;
esac
pct() {  # pct five_hour|seven_day -> integer percent, or empty
  printf '%s' "$json" | tr -d '\n' | sed -n "s/.*\"$1\"[^}]*\"used_percentage\"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p" | cut -d. -f1
}
h=$(pct five_hour); w=$(pct seven_day)
out=""
[ -n "$h" ] && out="5h ${h}%"
[ -n "$w" ] && out="${out:+$out · }wk ${w}%"
printf '%s' "$out"
