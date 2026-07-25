#!/bin/bash
# rpmlint must report no errors on the installed packages (warnings are
# reported but tolerated, matching Fedora review practice).
set -euxo pipefail

rpmlint --installed bash-completion --installed bash-completion-devel || {
    rc=$?
    # rpmlint exits 64 on errors, 66 on config problems; warnings exit 0
    echo "rpmlint exit code: $rc" >&2
    exit "$rc"
}

echo "RPMLINT OK"
