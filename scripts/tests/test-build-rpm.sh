#!/usr/bin/env bash
# Unit tests for scripts/build-rpm.sh and scripts/clean.sh.
#
# These run on the host with no network and no container runtime: the build
# script's curl and podman seams are pointed at stubs, and its tarball URL,
# checksum, cache, lock and staging directories at scratch paths. What is
# under test is the scripts' own validation, publication and locking —
# argument checking, when a cached tarball is reused versus re-fetched, that
# a bad download is never published, that an incomplete build never replaces
# a good one, that publication is all-or-nothing, that clean waits for
# in-flight builds, and that failed or cancelled work leaves no staging
# directories, temporary files or held locks behind.
#
# Concurrency is driven with FIFO handshakes, never with sleeps: the podman
# stub announces that it has started and then blocks until the test releases
# it, so every interleaving below is deterministic.
#
# Usage: scripts/tests/test-build-rpm.sh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)
under_test="${repo_root}/scripts/build-rpm.sh"
clean_under_test="${repo_root}/scripts/clean.sh"

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

# podman stub: record the argument vector, then act as the container would by
# writing packages into whatever directory is mounted at /out.
#
#   PODMAN_STUB_TAG            content written into each package, so a test can
#                              tell one generation's set from another
#   PODMAN_STUB_PARTIAL        write only the base package: an incomplete build
#   PODMAN_STUB_FAIL           exit non-zero without writing anything
#   PODMAN_STUB_STARTED_FIFO   announce that the build has reached the
#                              container step
#   PODMAN_STUB_WAIT_FIFO      block here until the test writes to the FIFO
#   PODMAN_STUB_PARTIAL_BEFORE_WAIT
#                              write only the base package before blocking,
#                              and the rest after being released
cat >"${stub_bin}/podman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${PODMAN_STUB_LOG}"

out=
for arg in "$@"; do
    case ${arg} in
        *:/out:z) out=${arg%%:/out:z} ;;
    esac
done
[[ -n ${out} ]] || { echo "podman stub: no /out mount in argv" >&2; exit 64; }

tag=${PODMAN_STUB_TAG:-generation}
write_base() {
    mkdir -p "${out}/srpm"
    echo "${tag}" >"${out}/bash-completion-2.18.0-1.fc43.noarch.rpm"
}
write_rest() {
    echo "${tag}" >"${out}/bash-completion-devel-2.18.0-1.fc43.noarch.rpm"
    echo "${tag}" >"${out}/srpm/bash-completion-2.18.0-1.fc43.src.rpm"
}

if [[ -n ${PODMAN_STUB_PARTIAL_BEFORE_WAIT:-} ]]; then
    write_base
fi

if [[ -n ${PODMAN_STUB_STARTED_FIFO:-} ]]; then
    echo started >"${PODMAN_STUB_STARTED_FIFO}"
fi
if [[ -n ${PODMAN_STUB_WAIT_FIFO:-} ]]; then
    read -r _ <"${PODMAN_STUB_WAIT_FIFO}"
fi

if [[ -n ${PODMAN_STUB_FAIL:-} ]]; then
    echo "podman stub: simulated build failure" >&2
    exit 1
fi

if [[ -z ${PODMAN_STUB_PARTIAL_BEFORE_WAIT:-} ]]; then
    write_base
fi
if [[ -z ${PODMAN_STUB_PARTIAL:-} ]]; then
    write_rest
fi
STUB
chmod +x "${stub_bin}/podman"

# Environment shared by every invocation of the script under test for a case.
case_env() {
    local case_dir=$1
    echo \
        "CURL=${stub_bin}/curl" \
        "PODMAN=${stub_bin}/podman" \
        "CURL_STUB_LOG=${case_dir}/curl.log" \
        "PODMAN_STUB_LOG=${case_dir}/podman.log" \
        "CURL_STUB_FIXTURE=${fixture}" \
        "TARBALL_URL=https://example.invalid/bash-completion-2.18.0.tar.xz" \
        "TARBALL_SHA256=${fixture_sha256}" \
        "CACHE_DIR=${case_dir}/cache" \
        "LOCK_DIR=${case_dir}/cache/locks" \
        "STAGING_ROOT=${case_dir}/.staging"
}

prepare_case() {
    local case_dir=$1
    mkdir -p "${case_dir}"
    : >"${case_dir}/curl.log"
    : >"${case_dir}/podman.log"
}

# Run the script under test for a case. Extra VAR=value arguments are added to
# its environment. Echoes the exit status; output lands in ${case_dir}/output.
run_build() {
    local case_dir=$1
    shift
    prepare_case "${case_dir}"
    local rc=0
    # shellcheck disable=SC2046  # deliberate word splitting of the env list
    env $(case_env "${case_dir}") "$@" \
        "${under_test}" fake-image "${case_dir}/out" \
        >"${case_dir}/output" 2>&1 || rc=$?
    echo "${rc}"
}

# Start the script under test in the background, in its own process group so
# a test can signal the whole build. Sets bg_pid, which is also the process
# group id: job control is off in a script, so the background job is not a
# group leader and setsid execs in place rather than forking.
#
# This cannot echo the pid instead — a command substitution would make the
# job a child of the substitution's subshell, and `wait` in the test would
# not find it.
bg_pid=
start_build_bg() {
    local case_dir=$1 output=$2
    shift 2
    # shellcheck disable=SC2046  # deliberate word splitting of the env list
    setsid env $(case_env "${case_dir}") "$@" \
        "${under_test}" fake-image "${case_dir}/out" \
        >"${output}" 2>&1 &
    bg_pid=$!
}

curl_calls() {
    grep -c . "$1/curl.log" || true
}

stray_temps() {
    find "$1/cache" -maxdepth 1 -name 'bash-completion-*.tar.xz.??????' \
        -printf '%f\n' 2>/dev/null || true
}

# Any staging directory at all, whether this invocation's or a leftover.
stray_staging() {
    find "$1/.staging" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true
}

cached_tarball() {
    echo "$1/cache/bash-completion-2.18.0.tar.xz"
}

# The published set, as "<file>:<tag>" lines, sorted. Empty when absent.
published_set() {
    local dir="$1/out"
    [[ -d ${dir} ]] || return 0
    (
        cd "${dir}" || return 0
        find . -type f -name '*.rpm' -printf '%P\n' | sort | while read -r f; do
            echo "${f}:$(cat "${f}")"
        done
    )
}

complete_set_for() {
    local tag=$1
    printf '%s\n' \
        "bash-completion-2.18.0-1.fc43.noarch.rpm:${tag}" \
        "bash-completion-devel-2.18.0-1.fc43.noarch.rpm:${tag}" \
        "srpm/bash-completion-2.18.0-1.fc43.src.rpm:${tag}" | sort
}

assert_published_set() {
    local case_dir=$1 tag=$2 what=$3
    local actual expected
    actual=$(published_set "${case_dir}")
    expected=$(complete_set_for "${tag}")
    [[ ${actual} == "${expected}" ]] ||
        fail "${what}: published set is not the complete '${tag}' set:
    expected: $(echo "${expected}" | tr '\n' ' ')
    actual:   $(echo "${actual}" | tr '\n' ' ')"
}

# True when the published directory holds exactly one complete generation of
# one of the named tags.
published_is_one_complete_generation() {
    local case_dir=$1 actual tag
    shift
    [[ -d "${case_dir}/out" ]] || return 1
    actual=$(published_set "${case_dir}")
    for tag in "$@"; do
        [[ ${actual} == "$(complete_set_for "${tag}")" ]] && return 0
    done
    return 1
}

# Both locks must be free once everything has finished.
assert_locks_free() {
    local case_dir=$1 what=$2
    local lock
    for lock in "${case_dir}/cache/locks/activity.lock" \
        "${case_dir}/cache/locks/publish-out.lock"; do
        [[ -e ${lock} ]] || continue
        flock -n -x "${lock}" true ||
            fail "${what}: lock '${lock}' is still held"
    done
}

# --- cases: argument handling and the tarball cache -------------------------

start 'rejects a wrong argument count'
rc=0
"${under_test}" >"${workdir}/usage.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for no arguments'
assert_contains "${workdir}/usage.out" 'usage:' 'usage message'
rc=0
"${under_test}" only-one >"${workdir}/usage1.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" 'exit status for one argument'

start 'downloads, builds and publishes on a cold cache'
c="${workdir}/cold"
rc=$(run_build "${c}" PODMAN_STUB_TAG=first)
assert_eq 0 "${rc}" 'exit status'
assert_eq 1 "$(curl_calls "${c}")" 'curl invocations'
assert_file "$(cached_tarball "${c}")" 'cached tarball'
assert_eq "${fixture_sha256}" \
    "$(sha256sum "$(cached_tarball "${c}")" | cut -d' ' -f1)" \
    'cached tarball checksum'
assert_published_set "${c}" first 'first publication'
assert_eq '' "$(stray_temps "${c}")" 'stray temporary files'
assert_eq '' "$(stray_staging "${c}")" 'staging directories left behind'

start 'reuses a cached tarball without downloading again'
rc=$(run_build "${c}" PODMAN_STUB_TAG=second)
assert_eq 0 "${rc}" 'exit status on second run'
assert_eq 0 "$(curl_calls "${c}")" 'curl invocations on a warm cache'
assert_published_set "${c}" second 'second publication replaced the first'

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

# --- cases: orchestration ---------------------------------------------------

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
# shellcheck disable=SC2016  # matching the literal, unexpanded container script
assert_contains "${log}" 'rpmbuild --define "_topdir ${topdir}" -ba /work/bash-completion.spec' \
    'rpmbuild invocation'
grep -qF -- "${c}/out:/out:z" "${log}" &&
    fail 'the published directory must not be mounted as the output directory'
assert_contains "${log}" "${c}/.staging/" 'a staging directory is mounted at /out'

# --- cases: validation before publication -----------------------------------

start 'refuses to publish an incomplete build'
c="${workdir}/incomplete"
rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
assert_eq 0 "${rc}" 'exit status priming a good publication'
rc=$(run_build "${c}" PODMAN_STUB_TAG=bad PODMAN_STUB_PARTIAL=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for an incomplete build'
assert_contains "${c}/output" 'incomplete build' 'incomplete build message'
assert_published_set "${c}" good 'the previous complete set survives'
assert_eq '' "$(stray_staging "${c}")" 'staging directories left behind'
assert_locks_free "${c}" 'after an incomplete build'

# --- cases: atomic publication ----------------------------------------------

# A second build is held inside the container step with a partial set already
# staged. Until it is released, the published directory must still be exactly
# the previous complete set — never empty, never a mixture.
publication_case() {
    local c=$1 exchange=$2
    prepare_case "${c}"
    local started="${c}/started.fifo" waiting="${c}/wait.fifo"
    mkfifo "${started}" "${waiting}"

    local rc
    rc=$(run_build "${c}" PODMAN_STUB_TAG=previous PUBLISH_EXCHANGE="${exchange}")
    assert_eq 0 "${rc}" "exit status priming the previous set (${exchange})"

    prepare_case "${c}"
    start_build_bg "${c}" "${c}/second.out" \
        PODMAN_STUB_TAG=next \
        PUBLISH_EXCHANGE="${exchange}" \
        PODMAN_STUB_PARTIAL_BEFORE_WAIT=1 \
        PODMAN_STUB_STARTED_FIFO="${started}" \
        PODMAN_STUB_WAIT_FIFO="${waiting}"
    local pid=${bg_pid}

    read -r _ <"${started}"
    # The second build is now blocked with a half-written staging directory.
    assert_published_set "${c}" previous \
        "while a second build is mid-flight (${exchange})"

    echo go >"${waiting}"
    wait "${pid}" || fail "second build failed (${exchange}): $(cat "${c}/second.out")"
    assert_published_set "${c}" next "after the second build published (${exchange})"
    assert_eq '' "$(stray_staging "${c}")" "staging left behind (${exchange})"
    assert_locks_free "${c}" "after publication (${exchange})"
}

start 'publication is all-or-nothing (atomic exchange)'
publication_case "${workdir}/publish-atomic" auto

start 'publication is all-or-nothing (fallback path)'
publication_case "${workdir}/publish-fallback" never

# Two builds of the same target, held together at the pre-publication barrier
# and then released into the publication lock at once. Neither the staged
# output of either build nor any mixture of the two may ever be visible: the
# published directory must hold one complete generation at every moment, and
# one complete generation at the end. Which of the two wins the lock is
# deliberately not asserted — that is the point of the lock, not a property
# of it.
start 'two concurrent builds never expose a partial or mixed generation'
c="${workdir}/concurrent-publish"
prepare_case "${c}"
announce_a="${c}/announce-a.fifo"
wait_a="${c}/wait-a.fifo"
announce_b="${c}/announce-b.fifo"
wait_b="${c}/wait-b.fifo"
mkfifo "${announce_a}" "${wait_a}" "${announce_b}" "${wait_b}"

rc=$(run_build "${c}" PODMAN_STUB_TAG=previous)
assert_eq 0 "${rc}" 'exit status priming the previous set'

prepare_case "${c}"
start_build_bg "${c}" "${c}/a.out" \
    PODMAN_STUB_TAG=build-a \
    PREPUBLISH_ANNOUNCE_FIFO="${announce_a}" \
    PREPUBLISH_WAIT_FIFO="${wait_a}"
pid_a=${bg_pid}
start_build_bg "${c}" "${c}/b.out" \
    PODMAN_STUB_TAG=build-b \
    PREPUBLISH_ANNOUNCE_FIFO="${announce_b}" \
    PREPUBLISH_WAIT_FIFO="${wait_b}"
pid_b=${bg_pid}

read -r _ <"${announce_a}"
read -r _ <"${announce_b}"

# Both builds now hold the activity lock with a complete, validated set
# staged and unpublished.
assert_published_set "${c}" previous 'while both builds wait to publish'
assert_eq 2 "$(stray_staging "${c}" | grep -c .)" \
    'staging directories in flight'

# Take the publication lock from outside, so that releasing both builds cannot
# publish anything. This is what makes the next assertion a statement about
# the lock rather than about timing: neither build can get past
# publish_staging's flock while this holder owns it, however long they run.
holder_ready="${c}/holder-ready.fifo"
holder_release="${c}/holder-release.fifo"
mkfifo "${holder_ready}" "${holder_release}"
flock -x "${c}/cache/locks/publish-out.lock" \
    -c "echo held >'${holder_ready}'; read -r _ <'${holder_release}'" &
holder_pid=$!
read -r _ <"${holder_ready}"

# Release both builds into the publication lock at once.
echo go >"${wait_a}" &
echo go >"${wait_b}" &

# Both are now past the barrier and blocked on the lock this test holds, so
# the published directory must still be exactly the previous generation, and
# neither build can have exited.
assert_published_set "${c}" previous 'while the publication lock is held'
kill -0 "${pid_a}" 2>/dev/null || fail 'build A exited without the publication lock'
kill -0 "${pid_b}" 2>/dev/null || fail 'build B exited without the publication lock'

echo go >"${holder_release}"
wait "${holder_pid}"
wait "${pid_a}" || fail "build A failed: $(cat "${c}/a.out")"
wait "${pid_b}" || fail "build B failed: $(cat "${c}/b.out")"

# Which build won the lock is deliberately not asserted; that it published
# alone, and whole, is.
published_is_one_complete_generation "${c}" build-a build-b ||
    fail "final published set is not one complete generation: [$(published_set "${c}")]"
assert_eq '' "$(stray_staging "${c}")" 'staging directories after the race'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after the race'
assert_locks_free "${c}" 'after two concurrent builds'

# --- cases: clean against an active build -----------------------------------

start 'clean waits for an in-flight build and keeps the lock directory'
c="${workdir}/clean-race"
prepare_case "${c}"
started="${c}/started.fifo"
waiting="${c}/wait.fifo"
clean_ready="${c}/clean.fifo"
mkfifo "${started}" "${waiting}" "${clean_ready}"

rc=$(run_build "${c}" PODMAN_STUB_TAG=published)
assert_eq 0 "${rc}" 'exit status priming the published set'

prepare_case "${c}"
start_build_bg "${c}" "${c}/build.out" \
    PODMAN_STUB_TAG=later \
    PODMAN_STUB_STARTED_FIFO="${started}" \
    PODMAN_STUB_WAIT_FIFO="${waiting}"
build_pid=${bg_pid}
read -r _ <"${started}"

# Announce-then-block: once the hook has fired, clean can only be waiting on
# the activity lock, which the running build holds shared.
cat >"${c}/prelock-hook" <<HOOK
#!/usr/bin/env bash
echo waiting >"${clean_ready}"
HOOK
chmod +x "${c}/prelock-hook"

env FLOCK=flock \
    CACHE_DIR="${c}/cache" \
    LOCK_DIR="${c}/cache/locks" \
    DIST_DIR="${c}/out" \
    CLEAN_PRELOCK_HOOK="${c}/prelock-hook" \
    "${clean_under_test}" >"${c}/clean.out" 2>&1 &
clean_pid=$!
read -r _ <"${clean_ready}"

assert_published_set "${c}" published 'clean must not touch output while a build runs'
assert_file "$(cached_tarball "${c}")" 'clean must not remove the cache yet'

echo go >"${waiting}"
wait "${build_pid}" || fail "build failed: $(cat "${c}/build.out")"
wait "${clean_pid}" || fail "clean failed: $(cat "${c}/clean.out")"

assert_no_file "${c}/out" 'output directory after clean'
assert_no_file "$(cached_tarball "${c}")" 'cached tarball after clean'
[[ -d "${c}/cache/locks" ]] ||
    fail 'clean removed the lock directory'
assert_locks_free "${c}" 'after clean'

# --- cases: failure and cancellation ----------------------------------------

start 'a failed build leaves no staging, temporaries or held locks'
c="${workdir}/build-failure"
rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
assert_eq 0 "${rc}" 'exit status priming a good publication'
rc=$(run_build "${c}" PODMAN_STUB_FAIL=1)
[[ ${rc} -ne 0 ]] || fail 'expected a non-zero exit status for a failed build'
assert_published_set "${c}" good 'the previous complete set survives a failure'
assert_eq '' "$(stray_staging "${c}")" 'staging directories after a failure'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after a failure'
assert_locks_free "${c}" 'after a failed build'

start 'a cancelled build leaves no staging, temporaries or held locks'
c="${workdir}/build-cancel"
prepare_case "${c}"
started="${c}/started.fifo"
waiting="${c}/wait.fifo"
mkfifo "${started}" "${waiting}"
rc=$(run_build "${c}" PODMAN_STUB_TAG=good)
assert_eq 0 "${rc}" 'exit status priming a good publication'

prepare_case "${c}"
start_build_bg "${c}" "${c}/cancelled.out" \
    PODMAN_STUB_TAG=doomed \
    PODMAN_STUB_PARTIAL_BEFORE_WAIT=1 \
    PODMAN_STUB_STARTED_FIFO="${started}" \
    PODMAN_STUB_WAIT_FIFO="${waiting}"
build_pid=${bg_pid}
read -r _ <"${started}"
# setsid gave the build its own process group, so this reaches the stub too.
kill -TERM -"${build_pid}"
wait "${build_pid}" 2>/dev/null || true

assert_published_set "${c}" good 'the previous complete set survives cancellation'
assert_eq '' "$(stray_staging "${c}")" 'staging directories after cancellation'
assert_eq '' "$(stray_temps "${c}")" 'temporary files after cancellation'
assert_locks_free "${c}" 'after cancellation'

# --- summary ----------------------------------------------------------------

echo
if [[ ${tests_failed} -gt 0 ]]; then
    echo "BUILD-RPM UNIT TESTS FAILED (${tests_failed} of ${tests_run} cases)" >&2
    exit 1
fi
echo "BUILD-RPM UNIT TESTS OK (${tests_run} cases)"
