#!/bin/bash
# Functional test: drive the installed bash-completion the way an interactive
# shell would, and check that real completions are produced.
set -euo pipefail
export LANG=C.UTF-8

# Print a failure message and abort the test.
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
#    get_completions "<command line>" prints one candidate per line. The
#    completion function's exit status is preserved: 0, 1 (no match), and
#    124 (spec reloaded, retry) are expected; anything else aborts.
get_completions() {
    local line=$1
    bash --norc -c '
        source /usr/share/bash-completion/bash_completion
        COMP_LINE=$1
        COMP_POINT=${#COMP_LINE}
        # Split on whitespace with read rather than "eval set --": every
        # command line this test drives is a plain unquoted literal, so no
        # shell-quoting needs interpreting and no input reaches the parser.
        read -ra COMP_WORDS <<<"$COMP_LINE"
        [[ $COMP_LINE == *" " ]] && COMP_WORDS+=("")
        COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
        cmd=${COMP_WORDS[0]}
        _comp_load "$cmd" || exit 1
        spec=$(complete -p "$cmd") || exit 1
        func=$(sed -E "s/.* -F ([^ ]+) .*/\1/" <<<"$spec")
        cur=${COMP_WORDS[COMP_CWORD]}
        prev=${COMP_WORDS[COMP_CWORD - 1]-}
        COMPREPLY=()
        rc=0
        "$func" "$cmd" "$cur" "$prev" || rc=$?
        case $rc in
            0 | 1 | 124) ;;
            *)
                echo "completion function $func failed with status $rc" >&2
                exit "$rc"
                ;;
        esac
        printf "%s\n" "${COMPREPLY[@]}"
    ' -- "$line"
}

# kill -<TAB> offers signal names
out=$(get_completions 'kill -')
echo "$out" | grep -qE 'HUP|TERM|KILL' || fail "kill -<TAB> offered no signals: $out"

# tar --<TAB> offers GNU tar long options
out=$(get_completions 'tar --')
echo "$out" | grep -q -- '--extract' || fail "tar --<TAB> offered no long options: $out"

# umount <TAB> offers the container's mount points (there is always at least
# one: /proc is mounted in every container)
out=$(get_completions 'umount ') || fail "umount completion failed"
test -n "$out" || fail "umount <TAB> offered no mount points"

# 4. Fallback registration: for a command with no completion file, invoking
#    the function registered through `complete -p -D` with a full completion
#    environment must request a retry (status 124) and re-register the
#    command with the minimal completion. _comp_complete_minimal itself
#    leaves COMPREPLY empty by design: it delegates filename generation to
#    readline via "compopt -o default", so the candidate itself cannot be
#    observed here (see step 5 for that).
bash --norc -c '
    source /usr/share/bash-completion/bash_completion
    cd /
    COMP_LINE="no-such-command-b7f3 /us"
    COMP_POINT=${#COMP_LINE}
    COMP_WORDS=(no-such-command-b7f3 /us)
    COMP_CWORD=1
    dfunc=$(complete -p -D | sed -E "s/.* -F ([^ ]+) .*/\1/")
    rc=0
    "$dfunc" "${COMP_WORDS[0]}" "${COMP_WORDS[1]}" "${COMP_WORDS[0]}" || rc=$?
    [ "$rc" -eq 124 ] || {
        echo "expected retry status 124 from $dfunc, got $rc" >&2
        exit 1
    }
    complete -p no-such-command-b7f3 | grep -q "_comp_complete_minimal" || {
        echo "minimal fallback completion not registered" >&2
        exit 1
    }
' || fail "fallback registration via the -D loader broken"

# 5. End-to-end fallback candidate: a real <TAB> press in an interactive
#    shell must complete "no-such-command-b7f3 /us" to /usr/ via the minimal
#    fallback's readline delegation. script(1) provides the pty that
#    readline needs.
rcfile=$(mktemp)
trap 'rm -f "$rcfile"' EXIT
echo 'source /usr/share/bash-completion/bash_completion' >"$rcfile"
out=$(printf 'no-such-command-b7f3 /us\t\necho DONE\nexit\n' |
    script -qec "bash --noprofile --rcfile $rcfile -i" /dev/null) || true
echo "$out" | grep -q 'no-such-command-b7f3 /usr/' ||
    fail "interactive <TAB> did not complete /us to /usr/: $out"

echo "FUNCTIONAL OK"
