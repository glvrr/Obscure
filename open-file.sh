#!/bin/bash
# Open a file the way the desktop intends. If the mime default handler is a
# terminal-bound .desktop entry (Terminal=true), run it inside the user's
# terminal (xdg-terminal-exec, Default Terminal Spec). Otherwise xdg-open.
set -u

path="$1"
if [ -z "$path" ] || [ ! -e "$path" ]; then
  xdg-open "$path" >/dev/null 2>&1
  exit 0
fi

mime=$(xdg-mime query filetype "$path" 2>/dev/null || true)
app=$(xdg-mime query default "$mime" 2>/dev/null || true)
entry=""
if [ -n "$app" ]; then
  for d in "$HOME/.local/share/applications" /usr/local/share/applications /usr/share/applications /var/lib/flatpak/exports/share/applications; do
    if [ -f "$d/$app" ]; then entry="$d/$app"; break; fi
  done
fi

if [ -n "$entry" ] && grep -q '^[[:space:]]*Terminal[[:space:]]*=[[:space:]]*true' "$entry"; then
  exec_line=$(awk -F= 'tolower($1)=="exec" { sub(/^[^=]*[[:space:]]*=[[:space:]]*/,""); print; exit }' "$entry")
  # Replace the first %f/%F/%u/%U code with the shell-quoted path, strip
  # the informational %i/%c/%k codes, then hand the command to the terminal.
  quoted=$(printf '%q' "$path")
  cmd=$(printf '%s' "$exec_line" | sed 's/%[fuFU]/__QP__/; s/%[ick]/X/g' | sed "s|__QP__|$quoted|")
  cd "$(dirname "$path")" 2>/dev/null || true
  exec xdg-terminal-exec -- sh -c "$cmd; exec \${SHELL:-bash}; exit 0" "open-file"
else
  exec xdg-open "$path"
fi