#!/bin/bash
# Open a file the way the desktop intends. If the mime default handler is a
# terminal-bound .desktop entry (Terminal=true), run it inside the user's
# terminal (xdg-terminal-exec, Default Terminal Spec). Otherwise xdg-open.
set -u

path="${1:-}"
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
  # Terminal=true with no Exec line cannot be launched at all: fall through to
  # xdg-open instead of opening a terminal that only reports a syntax error.
  if [ -n "$exec_line" ]; then
    # Desktop Entry field codes: %f/%F/%u/%U becomes the token "$1" and the
    # informational %i/%c/%k are dropped. Quotes that wrapped the code are
    # consumed, so the substitution is always a single quoted expansion
    # whatever the Exec line looked like (the rules are ordered: quoted first,
    # bare last).
    #
    # THE FILE NAME IS NEVER PART OF THE SHELL CODE. It is handed to sh as its
    # positional parameter and is only ever referenced as "$1", so not one byte
    # of a name is parsed as shell syntax: spaces, quotes, $, (), `, ;, &, |,
    # <, >, backslashes, embedded newlines and a leading dash all survive
    # verbatim, as exactly one argument.
    #
    # The previous version was exploitable. It ran the name through printf '%q'
    # (which escapes for a SHELL) and pasted the result into the REPLACEMENT
    # half of a sed s/// command, where sed consumed those backslashes as its
    # own escapes and handed the metacharacters back raw: a file named
    # 'a;id;.txt' reached sh -c as 'a;id;.txt' and the semicolon ran as a
    # command separator. Two escaping languages and one parse — the protection
    # one applied was eaten by the other.
    #
    # The sed script is double quoted so it can carry both quote characters;
    # \$1 is a literal $1 for sed's replacement, not a shell expansion. The
    # delimiter is | because it cannot appear in a field code and does not in
    # any Exec line on this system; if you pick another, re-check that.
    script=$(printf '%s' "$exec_line" |
      sed "s|\"\(%[fFuU]\)\"|\"\$1\"|g; s|'\(%[fFuU]\)'|\"\$1\"|g; s|%[fFuU]|\"\$1\"|g; s|%[ick]|X|g")
    cd "$(dirname -- "$path")" 2>/dev/null || true
    # $1 here is sh's positional parameter, never the shell's $1 from this
    # script, and "${SHELL:-bash}" stays quoted so a hostile SHELL cannot split.
    exec xdg-terminal-exec -- sh -c "$script; exec \"\${SHELL:-bash}\"; exit 0" open-file "$path"
  fi
fi

exec xdg-open "$path"
