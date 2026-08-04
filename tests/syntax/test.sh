#!/bin/bash
# Comprehensive sweep: every completion file shipped in the package must be
# valid bash (syntax check) and must actually source on top of the main
# bash_completion file without error.
set -euo pipefail
export LANG=C.UTF-8

datadir=/usr/share/bash-completion
loader="${datadir}/bash_completion"

files=$(rpm -ql bash-completion | grep -E "^${datadir}/(completions-core|completions-fallback)/.*\.bash$")
count=$(wc -l <<<"$files")
echo "Checking ${count} completion files"
test "$count" -gt 400 # the payload really is the full upstream set

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src_out="${work}/stdout"
src_err="${work}/stderr"

# Report a failure with everything needed to act on it.
report() {
    local file=$1 status=$2 what=$3
    echo "FAIL: ${what}" >&2
    echo "  file:   ${file}" >&2
    echo "  status: ${status}" >&2
    if [ -s "$src_out" ]; then
        echo "  stdout:" >&2
        sed 's/^/    /' "$src_out" >&2
    fi
    if [ -s "$src_err" ]; then
        echo "  stderr:" >&2
        sed 's/^/    /' "$src_err" >&2
    fi
}

# The loader itself must work before any per-file result means anything. A
# broken or missing bash_completion would otherwise make every file look
# fine or every file look broken, for the same reason.
loader_rc=0
bash --norc -c 'source "$1"' -- "$loader" >"$src_out" 2>"$src_err" || loader_rc=$?
if [ "$loader_rc" -ne 0 ] || [ -s "$src_err" ]; then
    report "$loader" "$loader_rc" "the bash_completion loader did not load cleanly"
    exit 1
fi

syntax_failures=0
for f in $files; do
    # extglob is enabled by bash_completion before these files are loaded,
    # so it must be enabled for the syntax check too
    rc=0
    bash -O extglob -n "$f" >"$src_out" 2>"$src_err" || rc=$?
    if [ "$rc" -ne 0 ] || [ -s "$src_err" ]; then
        report "$f" "$rc" "completion file is not valid bash"
        syntax_failures=$((syntax_failures + 1))
    fi
done
test "$syntax_failures" -eq 0

# Each file must source without emitting errors in a shell that has
# bash_completion loaded.
#
# The inner shell normalizes its exit status to a documented set, so an
# environmental failure cannot be mistaken for a completion file's own
# return value:
#
#   0  the file sourced and returned success
#   1  the file sourced and returned non-zero. Permitted: many completions
#      bail out early when the command they complete is not installed.
#   90 the loader failed inside this invocation
#
# Only 0 and 1 are allowed. Anything else — 90, a status the file forced by
# calling `exit`, 126/127 from the shell, or death by signal — is an
# environmental, I/O or sourcing failure and fails the test. stderr is still
# checked, but it is no longer the only signal.
source_failures=0
for f in $files; do
    # _comp_load sources completion files from inside a function, so file-scope
    # "local" is legal; emulate that here.
    rc=0
    bash --norc -c '
        set +e
        loader=$1
        file=$2
        source "$loader" || exit 90
        _t() { source "$file"; }
        _t
        [ $? -eq 0 ] && exit 0
        exit 1
    ' -- "$loader" "$f" >"$src_out" 2>"$src_err" || rc=$?

    case $rc in
        0 | 1)
            if [ -s "$src_err" ]; then
                report "$f" "$rc" "sourcing the completion file wrote to stderr"
                source_failures=$((source_failures + 1))
            fi
            ;;
        90)
            report "$f" "$rc" "the bash_completion loader failed while checking this file"
            source_failures=$((source_failures + 1))
            ;;
        *)
            report "$f" "$rc" "sourcing the completion file failed with a status outside the allowed set (0, 1)"
            source_failures=$((source_failures + 1))
            ;;
    esac
done
test "$source_failures" -eq 0

echo "SYNTAX OK (${count} files)"
