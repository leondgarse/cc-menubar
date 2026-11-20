#!/bin/sh
# Install statusline.sh as Claude Code and AGY status line, locally or on an SSH host.
# Usage: ./install-statusline.sh            # this machine
#        ./install-statusline.sh <ssh-dest>  # a remote server (needs jq or python3 there)
# Leaves an existing, different statusLine alone; backs up settings.json before changing it.
set -e
cd "$(dirname "$0")"

copy_cmd='mkdir -p "$HOME/.claude" && cat > "$HOME/.claude/cc-menubar-statusline.sh" && chmod +x "$HOME/.claude/cc-menubar-statusline.sh"'
setup=$(cat <<'EOF'
set -e
settings="$HOME/.claude/settings.json"
cmd="~/.claude/cc-menubar-statusline.sh"
[ -f "$settings" ] || echo '{}' > "$settings"
# Edit settings.json with jq, or python3 if jq is missing.
if command -v jq >/dev/null 2>&1; then
  cur=$(jq -r '.statusLine.command // empty' "$settings")
  set_hook() { jq --arg c "$cmd" '.statusLine = {"type":"command","command":$c}' "$settings" > "$settings.new"; }
elif command -v python3 >/dev/null 2>&1; then
  cur=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("statusLine") or {}).get("command",""))' "$settings")
  set_hook() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["statusLine"]={"type":"command","command":sys.argv[2]}; json.dump(d,open(sys.argv[1]+".new","w"),indent=2)' "$settings" "$cmd"; }
else
  echo "failed: needs jq or python3 to edit $settings"; exit 1
fi
if [ -z "$cur" ]; then
  cp "$settings" "$settings.bak-cc-menubar"
  set_hook
  mv "$settings.new" "$settings"
  echo "installed (backup: $settings.bak-cc-menubar)"
elif [ "$cur" = "$cmd" ]; then
  echo "already installed (script updated)"
else
  echo "skipped: settings.json already has a statusLine: $cur"
fi

# Antigravity (agy) settings
agy_dir="$HOME/.gemini/antigravity-cli"
if [ -d "$agy_dir" ]; then
  agy_settings="$agy_dir/settings.json"
  [ -f "$agy_settings" ] || echo '{}' > "$agy_settings"
  if command -v jq >/dev/null 2>&1; then
    agy_cur=$(jq -r '.statusLine.command // empty' "$agy_settings")
    set_agy_hook() { jq --arg c "$cmd" '.statusLine = {"command":$c}' "$agy_settings" > "$agy_settings.new"; }
  elif command -v python3 >/dev/null 2>&1; then
    agy_cur=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("statusLine") or {}).get("command",""))' "$agy_settings")
    set_agy_hook() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["statusLine"]={"command":sys.argv[2]}; json.dump(d,open(sys.argv[1]+".new","w"),indent=2)' "$agy_settings" "$cmd"; }
  fi
  if [ -z "$agy_cur" ]; then
    cp "$agy_settings" "$agy_settings.bak-cc-menubar"
    set_agy_hook
    mv "$agy_settings.new" "$agy_settings"
    echo "installed agy hook (backup: $agy_settings.bak-cc-menubar)"
  elif [ "$agy_cur" = "$cmd" ]; then
    echo "agy hook already installed"
  fi
fi
EOF
)

if [ -n "$1" ]; then
  # $SSH_OPTS: extra ssh options, e.g. from the menu bar app (word-split on purpose).
  ssh $SSH_OPTS "$1" "$copy_cmd" < statusline.sh
  printf '%s\n' "$setup" | ssh $SSH_OPTS "$1" sh -s
else
  sh -c "$copy_cmd" < statusline.sh
  printf '%s\n' "$setup" | sh -s
fi
