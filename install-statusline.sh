#!/bin/sh
# Install statusline.sh as Claude Code's status line, locally or on an SSH host.
# Usage: ./install-statusline.sh            # this machine
#        ./install-statusline.sh <ssh-dest>  # a remote server (needs jq there)
# Leaves an existing, different statusLine alone; backs up settings.json before changing it.
set -e
cd "$(dirname "$0")"

copy_cmd='mkdir -p "$HOME/.claude" && cat > "$HOME/.claude/cc-menubar-statusline.sh" && chmod +x "$HOME/.claude/cc-menubar-statusline.sh"'
setup=$(cat <<'EOF'
set -e
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
cur=$(jq -r '.statusLine.command // empty' "$settings")
if [ -z "$cur" ]; then
  cp "$settings" "$settings.bak-cc-menubar"
  jq '.statusLine = {"type":"command","command":"~/.claude/cc-menubar-statusline.sh"}' "$settings" > "$settings.new"
  mv "$settings.new" "$settings"
  echo "installed (backup: $settings.bak-cc-menubar)"
elif [ "$cur" = "~/.claude/cc-menubar-statusline.sh" ]; then
  echo "already installed (script updated)"
else
  echo "skipped: settings.json already has a statusLine: $cur"
fi
EOF
)

if [ -n "$1" ]; then
  ssh "$1" "$copy_cmd" < statusline.sh
  printf '%s\n' "$setup" | ssh "$1" sh -s
else
  sh -c "$copy_cmd" < statusline.sh
  printf '%s\n' "$setup" | sh -s
fi
