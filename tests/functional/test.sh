#!/bin/bash
# Functional test: drive the installed bash-completion the way an interactive
# shell would, and check that real completions are produced.
set -euo pipefail
export LANG=C.UTF-8

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 1. Sourcing registers the default dynamic completion loader.
bash --norc -c '
    source /usr/share/bash-completion/bash_completion
    complete -p -D
' | grep -q '_comp_complete_load' || fail "default loader (-D) not registered"

# 2. Completions load on demand via _comp_load.
bash --norc -c '
    source /usr/share/bash-completion/bash_completion
    _comp_load tar || exit 1
    complete -p tar >/dev/null || exit 1
    _comp_load kill || exit 1
    complete -p kill >/dev/null || exit 1
' || fail "dynamic completion loading failed"

# 3. Simulate <TAB> and inspect COMPREPLY, as an interactive shell would.
#    get_completions "<command line>" prints one candidate per line.
get_completions() {
    local line=$1
    bash --norc -c '
        source /usr/share/bash-completion/bash_completion
        COMP_LINE=$1
        COMP_POINT=${#COMP_LINE}
        eval set -- "$COMP_LINE"
        COMP_WORDS=("$@")
        [[ $COMP_LINE == *" " ]] && COMP_WORDS+=("")
        COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
        cmd=${COMP_WORDS[0]}
        _comp_load "$cmd" || exit 1
        spec=$(complete -p "$cmd") || exit 1
        func=$(sed -E "s/.* -F ([^ ]+) .*/\1/" <<<"$spec")
        cur=${COMP_WORDS[COMP_CWORD]}
        prev=${COMP_WORDS[COMP_CWORD - 1]-}
        COMPREPLY=()
        "$func" "$cmd" "$cur" "$prev" || true
        printf "%s\n" "${COMPREPLY[@]}"
    ' -- "$line"
}

# kill -<TAB> offers signal names
out=$(get_completions 'kill -')
echo "$out" | grep -qE 'HUP|TERM|KILL' || fail "kill -<TAB> offered no signals: $out"

# tar --<TAB> offers GNU tar long options
out=$(get_completions 'tar --')
echo "$out" | grep -q -- '--extract' || fail "tar --<TAB> offered no long options: $out"

# mount <TAB> after an option still behaves (no crash, sane exit)
out=$(get_completions 'umount ') || fail "umount completion crashed"

# 4. Filename fallback still works with bash-completion loaded:
#    completing a path prefix under / must offer usr/.
out=$(bash --norc -c '
    source /usr/share/bash-completion/bash_completion
    cd /
    compgen -d us
')
echo "$out" | grep -qx 'usr' || fail "directory completion for /us broken: $out"

echo "FUNCTIONAL OK"
