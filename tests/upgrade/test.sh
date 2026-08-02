#!/bin/bash
# Upgrade-path test: with the local build installed, a dnf upgrade against the
# distribution repositories must not replace it with the (older) distro RPM.
set -euxo pipefail

before=$(rpm -q --qf '%{EVR}' bash-completion)
test "${before%%-*}" = "1:2.18.0"

dnf -y upgrade bash-completion

after=$(rpm -q --qf '%{EVR}' bash-completion)
test "$after" = "$before"

# And the distro candidate really is older than what we ship.
repo_evr=$(dnf -q repoquery --qf '%{EVR}\n' bash-completion 2>/dev/null | sort -u | tail -n1 || true)
echo "distro candidate: ${repo_evr:-none}, installed: $after"
test -n "$repo_evr"
# Both values are interpolated into a Lua expression below, so check they
# look like EVRs first. This keeps the quoting of the generated expression
# well defined and catches malformed query output early.
evr_pattern='^[A-Za-z0-9._:+~^-]+$'
[[ $repo_evr =~ $evr_pattern ]] || {
    echo "unexpected repository EVR: $repo_evr" >&2
    exit 1
}
[[ $after =~ $evr_pattern ]] || {
    echo "unexpected installed EVR: $after" >&2
    exit 1
}
# rpm.vercmp compares full EVR strings; -1 means the candidate is older
cmp=$(rpm --eval "%{lua:print(rpm.vercmp('${repo_evr}', '${after}'))}")
test "$cmp" = "-1"

echo "UPGRADE OK"
