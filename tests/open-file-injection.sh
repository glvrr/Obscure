#!/bin/bash
# Security regression test for open-file.sh.
#
# The file NAME is the untrusted input: it can come from a download, an archive
# or another machine. It must never be able to run shell code, and it must reach
# the handler byte-for-byte as exactly one argument.
#
# Everything runs against stubs (xdg-mime / xdg-terminal-exec / xdg-open /
# handler) inside a temp sandbox, so no real terminal opens and no real desktop
# file is touched.
#
# Run: bash tests/open-file-injection.sh     (exit 0 = pass, 1 = fail)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUT="$ROOT/open-file.sh"

pass=0
fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
BIN="$SANDBOX/bin"
HOME_DIR="$SANDBOX/home"
WORK="$SANDBOX/work"
LOG="$SANDBOX/log"
mkdir -p "$BIN" "$HOME_DIR/.local/share/applications" "$WORK" "$LOG"

# ---------------------------------------------------------------- stubs -----
# Reports text/plain and the desktop entry named by OBC_HANDLER_FILE.
cat > "$BIN/xdg-mime" <<'STUB'
#!/bin/bash
if [ "$2" = "filetype" ]; then printf 'text/plain\n'
else printf '%s\n' "${OBC_HANDLER_FILE:-obc-term.desktop}"; fi
STUB

# Default Terminal Spec: everything after [--] is the command plus its argv.
cat > "$BIN/xdg-terminal-exec" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  [ "$1" = "--" ] && { shift; break; }
  shift
done
[ $# -gt 0 ] || exit 0
exec "$@"
STUB

cat > "$BIN/xdg-open" <<'STUB'
#!/bin/bash
printf 'opened\n' >> "$OBC_LOG/calls"
STUB

# Records that it ran, from where, how many arguments it got, and every argument
# NUL-separated so that names containing newlines stay measurable.
cat > "$BIN/obc-handler" <<'STUB'
#!/bin/bash
printf 'ran\n' >> "$OBC_LOG/calls"
printf 'cwd:%s\n' "$PWD" >> "$OBC_LOG/calls"
printf '%s\n' "$#" > "$OBC_LOG/nargs"
: > "$OBC_LOG/argv"
last=''
for a in "$@"; do
  printf '%s\0' "$a" >> "$OBC_LOG/argv"
  last="$a"
done
printf '%s\0' "$last" > "$OBC_LOG/last"
STUB
chmod +x "$BIN"/*

desktop() { # $1 = file name, $2 = Exec line, $3 = Terminal
  cat > "$HOME_DIR/.local/share/applications/$1" <<EOF
[Desktop Entry]
Type=Application
Name=OBC Test
Exec=$2
Terminal=$3
EOF
}
desktop obc-term.desktop 'obc-handler %f' true
desktop obc-quoted.desktop 'obc-handler "%f"' true
desktop obc-squoted.desktop "obc-handler '%f'" true
desktop obc-noarg.desktop 'obc-handler' true
desktop obc-noexec.desktop '' true
desktop obc-graphical.desktop 'obc-handler %f' false
desktop obc-meta.desktop 'obc-handler --template "a<b&c>d" %f' true

run_sut() { # everything after the first arg is passed to open-file.sh
  rm -rf "$LOG"
  mkdir -p "$LOG"
  ( cd "$WORK" && PATH="$BIN:$PATH" HOME="$HOME_DIR" OBC_LOG="$LOG" \
      OBC_HANDLER_FILE="${HANDLER:-obc-term.desktop}" \
      bash "$SUT" "$@" ) >/dev/null 2>&1
  printf '%s' "$?" > "$SANDBOX/rc"
}

ran_handler() { [ -f "$LOG/calls" ] && grep -q '^ran$' "$LOG/calls"; }
went_to_xdg_open() { [ -f "$LOG/calls" ] && grep -q '^opened$' "$LOG/calls"; }

# ------------------------------------------------------- positive control ---
# Prove the sandbox can SEE a command run. Without this, every assertion below
# would pass vacuously.
rm -rf "$WORK"; mkdir -p "$WORK"
( cd "$WORK" && PATH="$BIN:$PATH" OBC_LOG="$LOG" \
    /bin/sh -c "obc-handler a;touch pwned;.txt" ) >/dev/null 2>&1
if [ -e "$WORK/pwned" ]; then
  ok 'control: an injected command IS observable in this sandbox'
else
  no 'control: injected command left no trace — nothing below would prove anything'
fi

# --------------------------------------------------------- the regression ---
# For every case: the sandbox must still hold exactly the files we created
# (anything else means a payload ran or a redirect fired), the handler must
# have run, it must have got exactly the expected number of arguments, and its
# LAST argument must be the path, byte for byte — which also proves the name was
# never split, globbed or glued onto a neighbour.
#
# Marker names are relative ("touch pwned") on purpose: a payload containing an
# absolute path cannot be a single file name at all, since / separates
# directories. The CWD of the handler is the file's own directory.
check_name() { # $1 = label, $2 = file name, $3 = expected argc, $4.. = siblings
  local label="$1" name="$2" argc="$3" path="$WORK/$2" before after sib
  shift 3
  rm -rf "$WORK"; mkdir -p "$WORK"
  : > "$WORK/$name"
  for sib in "$@"; do : > "$WORK/$sib"; done
  before=$(ls -A "$WORK" | tr '\n' '|')

  run_sut "$path"

  after=$(ls -A "$WORK" | tr '\n' '|')
  if [ "$before" != "$after" ]; then
    no "$label — sandbox changed: [$after] (shell code ran?)"
    return
  fi
  if ! ran_handler; then
    no "$label — handler never ran"
    return
  fi
  if [ "$(cat "$LOG/nargs")" != "$argc" ]; then
    no "$label — handler got $(cat "$LOG/nargs") arguments, expected $argc"
    return
  fi
  printf '%s\0' "$path" > "$SANDBOX/expect"
  if ! cmp -s "$LOG/last" "$SANDBOX/expect"; then
    no "$label — last argument differs from the real path byte-for-byte"
    return
  fi
  ok "$label"
}

printf '\nbaseline:\n'
check_name 'normal.txt' 'normal.txt' 1

printf '\ncommand separators and substitutions:\n'
check_name 'semicolon'            'a;b.txt' 1
check_name 'semicolon spaced'     'a ; touch pwned ; .txt' 1
check_name 'ampersand'            'a&b.txt' 1
check_name 'background ampersand' 'a & touch pwned & .txt' 1
check_name 'pipe'                 'a | touch pwned | .txt' 1
check_name 'dollar-paren'         '$(touch pwned).txt' 1
check_name 'backtick'             '`touch pwned`.txt' 1
check_name 'double-quoted payload' 'a"$(touch pwned)".txt' 1
check_name 'single-quoted payload' "a'\$(touch pwned)'.txt" 1
check_name 'escaped semicolon'    'a\;touch pwned.txt' 1
check_name 'redirect out'         'a > pwned.txt' 1
check_name 'redirect in'          'a < pwned.txt' 1 'pwned.txt'
check_name 'newline'              "$(printf 'a\ntouch pwned\n.txt')" 1

printf '\nvariable and tilde expansion:\n'
check_name 'dollar var'           '$(HOME).txt' 1
check_name 'braced var'           '${HOME}.txt' 1
check_name 'IFS var'              '${IFS}.txt' 1
check_name 'tilde'                '~root.txt' 1

printf '\nglobbing (must not expand):\n'
check_name 'star'                 '*.txt' 1 'a1.txt' 'a2.txt'
check_name 'question'             'a?b.txt' 1 'axb.txt'
check_name 'bracket'              'a[bc].txt' 1 'ab.txt' 'ac.txt'
check_name 'brace'                'a{b,c}.txt' 1 'ab.txt' 'ac.txt'
check_name 'tilde in middle'      'a~b.txt' 1

printf '\nquoting characters:\n'
check_name 'double quote'         'a"q".txt' 1
check_name 'single quote'         "it's.txt" 1
check_name 'backslash'            'back\slash.txt' 1
check_name 'tab'                  "$(printf 'a\tb.txt')" 1
check_name 'bang'                 'a!.txt' 1
check_name 'hash'                 'a#b.txt' 1
check_name 'dollar alone'         'a$.txt' 1

printf '\nleading dash and encoding:\n'
check_name 'leading dash'         '-leading-dash.txt' 1
check_name 'leading dash rm -rf'  '-rf.txt' 1
check_name 'unicode'              'файл.txt' 1
check_name 'emoji'                '🙂.txt' 1
check_name 'invalid utf-8'        "$(printf 'bad\xff.txt')" 1

printf '\nExec line variations (field codes must stay one argument):\n'
HANDLER=obc-quoted.desktop
check_name 'quoted %f' 'a;b c.txt' 1
HANDLER=obc-squoted.desktop
check_name 'single-quoted %f' 'a;b c.txt' 1
HANDLER=obc-meta.desktop
check_name 'metachars in other args' 'a b;c.txt' 3
HANDLER=obc-term.desktop

# ------------------------------------------------- behaviour preservation ----
printf '\nbehaviour that must not regress:\n'

rm -rf "$WORK"; mkdir -p "$WORK"; : > "$WORK/plain.txt"
run_sut "$WORK/plain.txt"
if ran_handler && [ "$(cat "$LOG/nargs")" = "1" ]; then
  ok 'Terminal=true handler still receives the path'
else
  no 'Terminal=true handler path broken'
fi
if grep -q "^cwd:$WORK\$" "$LOG/calls"; then
  ok "handler still runs in the file's directory"
else
  no 'cd into the file directory regressed'
fi

rm -rf "$WORK"; mkdir -p "$WORK"; : > "$WORK/plain.txt"
HANDLER=obc-graphical.desktop
run_sut "$WORK/plain.txt"
if went_to_xdg_open && ! ran_handler; then
  ok 'Terminal=false still goes to xdg-open'
else
  no 'Terminal=false routing regressed'
fi

HANDLER=obc-noexec.desktop
run_sut "$WORK/plain.txt"
if went_to_xdg_open && ! ran_handler; then
  ok 'Terminal=true with no Exec falls back to xdg-open'
else
  no 'empty Exec line did not fall back'
fi

HANDLER=obc-noarg.desktop
run_sut "$WORK/plain.txt"
if ran_handler && [ "$(cat "$LOG/nargs")" = "0" ]; then
  ok 'Exec without a field code still runs (no stray argument)'
else
  no 'Exec without a field code regressed'
fi

HANDLER=obc-term.desktop
rm -rf "$WORK"; mkdir -p "$WORK"
run_sut "$WORK/does-not-exist.txt"
if went_to_xdg_open && ! ran_handler; then
  ok 'missing file still falls back to xdg-open'
else
  no 'missing-file fallback regressed'
fi

run_sut
if [ "$(cat "$SANDBOX/rc")" = "0" ]; then
  ok 'no argument at all exits cleanly (no unbound variable)'
else
  no 'invocation without arguments failed'
fi

# The script must hand SHELL to the inner shell QUOTED. An unquoted
# ${SHELL:-bash} word-splits, and the first word of a hostile value is then
# exec'd as a command — "SHELL=touch /tmp/pwned" would create the file.
rm -rf "$WORK"; mkdir -p "$WORK"; : > "$WORK/plain.txt"
export SHELL="touch $WORK/SHELLMARK"
run_sut "$WORK/plain.txt"
unset SHELL
if [ -e "$WORK/SHELLMARK" ]; then
  no 'an unquoted $SHELL executed its first word as a command'
elif ran_handler; then
  ok 'hostile $SHELL stays inert (handler still ran)'
else
  no 'hostile $SHELL broke the handler'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
