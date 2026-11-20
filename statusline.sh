#!/bin/sh
# Claude Code and Antigravity (agy) status line hook for cc-menubar.
# Claude Code pipes session JSON (with rate_limits) or AGY pipes session JSON (with quota).
# We save it for the menu bar app and print a short status line.
dir="$HOME/.cache/cc-menubar"
mkdir -p "$dir"
json=$(cat)
case "$json" in
  *'"rate_limits"'*)
    printf '%s' "$json" > "$dir/usage.json.tmp" && mv "$dir/usage.json.tmp" "$dir/usage.json"
    pct() {
      printf '%s' "$json" | tr -d '\n' | sed -n "s/.*\"$1\"[^}]*\"used_percentage\"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p" | cut -d. -f1
    }
    h=$(pct five_hour); w=$(pct seven_day)
    out=""
    [ -n "$h" ] && out="5h ${h}%"
    [ -n "$w" ] && out="${out:+$out · }wk ${w}%"
    printf '%s' "$out"
    ;;
  *'"quota"'*)
    printf '%s' "$json" > "$dir/agy-usage.json.tmp" && mv "$dir/agy-usage.json.tmp" "$dir/agy-usage.json"
    if command -v python3 >/dev/null 2>&1; then
      printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("quota", {})
    def get_pct(k):
        v = d.get(k)
        if v and "remaining_fraction" in v:
            return max(0, min(100, int(round((1.0 - float(v["remaining_fraction"])) * 100))))
        return None
    parts = []
    g = get_pct("gemini-weekly") if get_pct("gemini-weekly") is not None else get_pct("gemini-5h")
    if g is not None: parts.append("gem %d%%" % g)
    a = get_pct("gemini-argon-wtu-weekly")
    if a is not None: parts.append("arg %d%%" % a)
    tp = get_pct("3p-weekly") if get_pct("3p-weekly") is not None else get_pct("3p-5h")
    if tp is not None: parts.append("3p %d%%" % tp)
    print(" · ".join(parts), end="")
except Exception:
    pass
'
    fi
    ;;
esac
