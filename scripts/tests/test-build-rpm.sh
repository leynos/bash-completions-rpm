#!/usr/bin/env bash
# Unit tests for scripts/build-rpm.sh.
#
# These run on the host with no network and no container runtime: the script's
# curl and podman seams are pointed at stubs, and its tarball URL, checksum
# and cache directory at a local fixture under a scratch directory. What is
# under test is the script's own validation and orchestration — argument
# checking, when a cached tarball is reused versus re-fetched, that a bad
# download is never published, that nothing is left behind on failure, that
# concurrent invocations converge on one good file, and that the container is
# invoked with the mounts and image it should be.
#
# Usage: scripts/tests/test-build-rpm.sh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
under_test="${repo_root}/scripts/build-rpm.sh"

tests_run=0
tests_failed=0
current_test=

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

# --- harness ----------------------------------------------------------------

fail() {
    echo "  FAIL: $*" >&2
    tests_failed=$((tests_failed + 1))
}

start() {
    current_test=$1
    tests_run=$((tests_run + 1))
    echo "- ${current_test}"
}

assert_eq() {
    local expected=$1 actual=$2 what=$3
    [[ ${expected} == "${actual}" ]] ||
        fail "${what}: expected '${expected}', got '${actual}'"
}

assert_file() {
    [[ -f $1 ]] || fail "$2: expected file '$1' to exist"
}

assert_no_file() {
    [[ ! -e $1 ]] || fail "$2: expected '$1' not to exist"
}

assert_contains() {
    grep -qF -- "$2" "$1" || fail "$3: '$1' does not contain '$2'"
}

# --- fixtures ---------------------------------------------------------------

# Stand-in for the upstream release tarball. Its content is irrelevant; only
# its checksum matters to the script.
fixture="${workdir}/upstream-tarball"
printf 'not really a tarball, but a stable one\n' >"${fixture}"
fixture_sha256=$(sha256sum "${fixture}" | cut -d' ' -f1)

stub_bin="${workdir}/bin"
mkdir -p "${stub_bin}"

# curl stub: append the requested URL to a call log, then serve the fixture
# (or, when CURL_STUB_CORRUPT is set, deliberately wrong content) to the path
# given after -o.
cat >"${stub_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out=
url=
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
echo "${url}" >>"${CURL_STUB_LOG}"
if [[ -n ${CURL_STUB_FAIL:-} ]]; then
    echo "curl stub: simulated transfer failure" >&2
    exit 22
fi
if [[ -n ${CURL_STUB_CORRUPT:-} ]]; then
    printf 'truncated junk' >"${out}"
else
    cat "${CURL_STUB_FIXTURE}" >"${out}"
fi
STUB
chmod +x "${stub_bin}/curl"

# podman stub: record the full argument vector, one argument per line.
cat >"${stub_bin}/podman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${PODMAN_STUB_LOG}"
STUB
chmod +x "${stub_bin}/podman"

# Run the script under test against a per-case cache directory and output
# directory, with the stubs wired in. Echoes the exit status; stdout and
# stderr of the run land in ${case_dir}/output.
run_build() {
    local case_dir=$1
    shift
    mkdir -p "${case_dir}"
    : >"${case_dir}/curl.log"
    : >"${case_dir}/podman.log"

    local rc=0
    env \
        CURL="${stub_bin}/curl" \
        PODMAN="${stub_bin}/podman" \
        CURL_STUB_LOG="${case_dir}/curl.log" \
        PODMAN_STUB_LOG="${case_dir}/podman.log" \
        CURL_STUB_FIXTURE="${fixture}" \
        TARBALL_URL="https://example.invalid/bash-completion-2.18.0.tar.xz" \
        TARBALL_SHA256="${fixture_sha256}" \
        CACHE_DIR="${case_dir}/cache" \
        "$@" \
        "${under_test}" fake-image "${case_dir}/out" \
        >"${case_dir}/output" 2>&1 || rc=$?
    echo "${rc}"
}

# How many times the curl stub was invoked for a case.
curl_calls() {
    grep -c . "$1/curl.log" || true
}

# Names of any stray temporary files left in a case's cache directory.
stray_temps() {
    find "$1/cache" -name 'bash-completion-*.tar.xz.??????' -printf '%f\n' 2>/dev/null || true
}

cached_tarball() {
    echo "$1/cache/bash-completion-2.18.0.tar.xz"
}

# --- cases ------------------------------------------------------------------

start 'rejects a wrong argument count'
rc=0
"${under_test}" >"${workdir}/usage.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for no arguments'
assert_contains "${workdir}/usage.out" 'usage:' 'usage message'
rc=0
"${under_test}" only-one >"${workdir}/usage1.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for one argument'

start 'downloads and publishes the tarball on a cold cache'
c="${workdir}/cold"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status'
assert_eq 1 "$(curl_calls "${c}")" 'curl invocations'
assert_file "$(cached_tarball "${c}")" 'cached tarball'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'cached tarball checksum'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files'

start 'reuses a cached tarball without downloading again'
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status on second run'
assert_eq 0 "$(curl_calls "${c}")" 'curl invocations on a warm cache'
assert_file "$(cached_tarball "${c}")" 'cached tarball still present'

start 're-fetches when the cached tarball fails its checksum'
c="${workdir}/corrupt"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status priming the cache'
printf 'clobbered by an interrupted run' >"$(cached_tarball "${c}")"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status with a corrupt cache'
assert_eq 1 "$(curl_calls "${c}")" 'curl invocations after corruption'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'repaired tarball checksum'

start 'never publishes a download that fails its checksum'
c="${workdir}/badsum"
rc=$(run_build "${c}" CURL_STUB_CORRUPT=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a bad download'
assert_contains "${c}/output" 'checksum mismatch' 'checksum failure message'
assert_no_file "$(cached_tarball "${c}")" 'cache file after a bad download'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files after failure'
assert_eq 0 "$(grep -c . "${c}/podman.log" || true)" \
    'container invocations after a failed download'

start 'leaves nothing behind when the transfer itself fails'
c="${workdir}/transfer"
rc=$(run_build "${c}" CURL_STUB_FAIL=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed transfer'
assert_no_file "$(cached_tarball "${c}")" 'cache file after a failed transfer'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files after failure'

start 'invokes the container with the expected image and mounts'
c="${workdir}/orchestration"
rc=$(run_build "${c}")
assert_eq 0 "${rc}" 'exit status'
log="${c}/podman.log"
assert_contains "${log}" 'run' 'podman subcommand'
assert_contains "${log}" '--rm' 'container is removed after the build'
assert_contains "${log}" 'fake-image' 'image argument'
assert_contains "${log}" "${repo_root}/bash-completion.spec:/work/bash-completion.spec:ro,z" \
    'spec mount'
assert_contains "${log}" "$(cached_tarball "${c}"):/work/bash-completion-2.18.0.tar.xz:ro,z" \
    'tarball mount'
assert_contains "${log}" "${c}/out:/out:z" 'output mount'
# shellcheck disable=SC2016  # matching the literal, unexpanded container script
assert_contains "${log}" 'rpmbuild --define "_topdir ${topdir}" -ba /work/bash-completion.spec' \
    'rpmbuild invocation'
assert_contains "${log}" 'rm -f /out/*.rpm /out/srpm/*.rpm' \
    'stale artefacts cleared before publishing'
[[ -d "${c}/out" ]] || fail 'output directory was not created'

start 'concurrent invocations converge on one good tarball'
c="${workdir}/concurrent"
mkdir -p "${c}"
: >"${c}/curl.log"
: >"${c}/podman.log"
pids=()
for i in $(seq 8); do
    env \
        CURL="${stub_bin}/curl" \
        PODMAN="${stub_bin}/podman" \
        CURL_STUB_LOG="${c}/curl.log" \
        PODMAN_STUB_LOG="${c}/podman.log" \
        CURL_STUB_FIXTURE="${fixture}" \
        TARBALL_URL="https://example.invalid/bash-completion-2.18.0.tar.xz" \
        TARBALL_SHA256="${fixture_sha256}" \
        CACHE_DIR="${c}/cache" \
        "${under_test}" fake-image "${c}/out-${i}" \
        >"${c}/output-${i}" 2>&1 &
    pids+=($!)
done
concurrent_failures=0
for pid in "${pids[@]}"; do
    wait "${pid}" || concurrent_failures=$((concurrent_failures + 1))
done
assert_eq 0 "${concurrent_failures}" 'failed concurrent invocations'
assert_file "$(cached_tarball "${c}")" 'cached tarball after concurrent runs'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'cached tarball checksum after concurrent runs'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files after concurrent runs'

# --- summary ----------------------------------------------------------------

echo
if [[ ${tests_failed} -gt 0 ]]; then
    echo "BUILD-RPM UNIT TESTS FAILED (${tests_failed} of ${tests_run} cases)" >&2
    exit 1
fi
echo "BUILD-RPM UNIT TESTS OK (${tests_run} cases)"
