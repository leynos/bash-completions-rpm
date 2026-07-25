#!/bin/bash
# Comprehensive sweep: every completion file shipped in the package must be
# valid bash (syntax check) and must actually source on top of the main
# bash_completion file without error.
set -euo pipefail
export LANG=C.UTF-8

datadir=/usr/share/bash-completion
files=$(rpm -ql bash-completion | grep -E "^${datadir}/(completions-core|completions-fallback)/.*\.bash$")
count=$(wc -l <<<"$files")
echo "Checking ${count} completion files"
test "$count" -gt 400 # the payload really is the full upstream set

syntax_failures=0
for f in $files; do
    # extglob is enabled by bash_completion before these files are loaded,
    # so it must be enabled for the syntax check too
    if ! bash -O extglob -n "$f"; then
        echo "SYNTAX FAIL: $f" >&2
        syntax_failures=$((syntax_failures + 1))
    fi
done
test "$syntax_failures" -eq 0

# Each file must source without emitting errors in a shell that has
# bash_completion loaded. A non-zero exit status alone is fine: many
# completions return early when the command they complete is not installed.
src_err=$(mktemp)
trap 'rm -f "$src_err"' EXIT

source_failures=0
for f in $files; do
    # _comp_load sources completion files from inside a function, so file-scope
    # "local" is legal; emulate that here.
    bash --norc -c "source ${datadir}/bash_completion && _t() { source '$f'; }; _t" 2>"$src_err" || true
    if [ -s "$src_err" ]; then
        echo "SOURCE FAIL: $f" >&2
        cat "$src_err" >&2
        source_failures=$((source_failures + 1))
    fi
done
test "$source_failures" -eq 0

echo "SYNTAX OK (${count} files)"
