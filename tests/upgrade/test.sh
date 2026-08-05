#!/bin/bash
# Upgrade-path test: with the local build installed, a dnf upgrade against the
# distribution repositories must not replace it with the (older) distro RPM.
set -euxo pipefail

repo_err=$(mktemp)
trap 'rm -f "$repo_err"' EXIT

before=$(rpm -q --qf '%{EVR}' bash-completion)
test "${before%%-*}" = "1:2.18.0"

dnf -y upgrade bash-completion

after=$(rpm -q --qf '%{EVR}' bash-completion)
test "$after" = "$before"

# And the distro candidate really is older than what we ship. --latest-limit=1
# makes dnf pick the highest candidate by RPM version ordering; sorting the
# lines here instead would order them lexically, which gets version
# comparisons wrong (2.9 would beat 2.10). More than one line coming back is
# unexpected and fails the pattern check below rather than being silently
# narrowed.
#
# The query's own failure is a real failure of this test, not something to
# swallow: a broken repository configuration would otherwise look exactly
# like "no candidate" and quietly weaken the assertion. Capture stderr and
# the exit status and report both.
set +x
repo_query_rc=0
repo_evr=$(dnf -q repoquery --latest-limit=1 --qf '%{EVR}\n' bash-completion 2>"$repo_err") ||
    repo_query_rc=$?
set -x
if [ "$repo_query_rc" -ne 0 ]; then
    echo "FAIL: dnf repoquery for bash-completion failed with status ${repo_query_rc}" >&2
    echo "dnf stderr:" >&2
    cat "$repo_err" >&2
    exit 1
fi
echo "distro candidate: ${repo_evr:-none}, installed: $after"
if [ -z "$repo_evr" ]; then
    echo "FAIL: dnf repoquery succeeded but returned no EVR for bash-completion" >&2
    cat "$repo_err" >&2
    exit 1
fi
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

# Bounded property check on the ordering invariant. The single comparison
# above only covers whichever candidate the repositories happen to offer
# today. What must hold is stronger: the EVR this package ships outranks
# every EVR either distribution has plausibly shipped or might ship in the
# 2.x series, including epoch-less forms and the epoch-1 forms Fedora uses.
# Each case is also checked for antisymmetry, so a comparison that silently
# returned 0 for both directions could not pass.
set +x
older_evrs=(
    2.7-5.el7
    2.8-6.el8
    2.11-4.el9
    2.11-10.el9
    1:2.11-13.el10
    1:2.14.0-1.el10
    1:2.16.0-1.el10
    1:2.16.0-4.el10
    1:2.16.0-8.fc42
    1:2.17.0-1.fc43
    1:2.18.0-1
    1:2.18.0-0.1.rc1
    1:2.18.0~rc1-1.fc43
)
property_failures=0
for evr in "${older_evrs[@]}"; do
    forward=$(rpm --eval "%{lua:print(rpm.vercmp('${evr}', '${after}'))}")
    reverse=$(rpm --eval "%{lua:print(rpm.vercmp('${after}', '${evr}'))}")
    if [ "$forward" != "-1" ] || [ "$reverse" != "1" ]; then
        echo "ORDERING FAIL: ${evr} vs ${after}: forward=${forward} reverse=${reverse}" >&2
        property_failures=$((property_failures + 1))
    fi
done
set -x
test "$property_failures" -eq 0
echo "ordering invariant holds against ${#older_evrs[@]} candidate EVRs"

echo "UPGRADE OK"
