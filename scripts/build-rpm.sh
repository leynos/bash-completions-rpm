#!/usr/bin/env bash
# Build the bash-completion RPM inside a podman container for a given target.
#
# Usage: scripts/build-rpm.sh <image> <outdir>
#   <image>   container image to build in (e.g. registry.fedoraproject.org/fedora:43)
#   <outdir>  directory to place the built RPMs in (relative to the repo root)
#
# Ownership model
#   .build/            the checksum-verified upstream tarball cache, plus
#                      .build/locks/. Shared by every target and every
#                      concurrent invocation; owned by no single build.
#   <outdir>/          published output. Only ever replaced whole, by the
#                      publish step below. Never mounted into the container.
#   <outdir>/../.staging/
#                      per-invocation staging directories. Each belongs to
#                      exactly one invocation, which removes its own on exit.
#                      A <staging>.previous directory is recovery data and is
#                      deliberately never removed by cleanup.
#   make clean         removes dist/ and the cached tarball, keeping
#                      .build/locks/; see scripts/clean.sh.
#
# Locking
#   .build/locks/activity.lock       held SHARED for the whole of this script.
#                                    scripts/clean.sh takes it EXCLUSIVE, so
#                                    clean never runs while a build is active.
#   .build/locks/publish-<name>.lock held EXCLUSIVE across the publish step,
#                                    so two builds of the same target cannot
#                                    interleave their swaps.
#
# Diagnostics
#   Lifecycle events are written to stdout as single-line key=value records
#   prefixed with "build_event", so a CI log can be grepped or parsed. Every
#   record carries event, target, build_id and elapsed_seconds. A free-form
#   detail="..." field, when present, is always last.
#
#   Secrets never reach the log. TARBALL_URL is overridable and may carry
#   userinfo or a query token, so it is never logged, in whole or in part;
#   downloads are reported by tarball filename only, and any diagnostic
#   captured from curl is passed through redact_secrets first.
#
# Every external command and every input pinned below can be overridden from
# the environment. Real builds override none of them; the seams exist so
# scripts/tests/test-build-rpm.sh can drive the download, caching,
# orchestration, validation and publication logic against stub commands and a
# local fixture, without a network or a container runtime.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <image> <outdir>" >&2
    exit 2
fi

image=$1
outdir=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)

# <outdir> is normally relative to the repo root; an absolute path is taken
# as given, which is what the unit tests use to stay out of the checkout.
if [[ ${outdir} == /* ]]; then
    outdir_path=${outdir}
else
    outdir_path=${repo_root}/${outdir}
fi
target_name=$(basename "${outdir_path}")

# Injectable command seams.
: "${CURL:=curl}"
: "${SHA256SUM:=sha256sum}"
: "${PODMAN:=podman}"
: "${FLOCK:=flock}"
# Used only for the two publication moves on the fallback path: promoting
# staging to the output path, and rolling the previous output back if that
# promotion fails. Scoped this narrowly so a test stub cannot disturb the
# unrelated renames in this script.
: "${PUBLISH_MV:=mv}"

# Injectable inputs.
: "${VERSION:=2.18.0}"
version=${VERSION}
tarball="bash-completion-${version}.tar.xz"
: "${TARBALL_URL:=https://github.com/scop/bash-completion/releases/download/${version}/${tarball}}"
: "${TARBALL_SHA256:=88bcf85124f77f74f2f2f8bcd16ac4382d807a827ede742a64940c7116aea33f}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
# Staging sits beside the published directory so that promoting it is a
# rename within one filesystem rather than a copy.
: "${STAGING_ROOT:=$(dirname "${outdir_path}")/.staging}"
# "never" forces the non-atomic fallback in publish_staging; the unit tests
# use it to cover both publication paths on any host.
: "${PUBLISH_EXCHANGE:=auto}"

tarball_url=${TARBALL_URL}
tarball_sha256=${TARBALL_SHA256}
cache_dir=${CACHE_DIR}

download_tmp=
staging_dir=

# Identifies this invocation in the log. Derived from the pid and bash's
# seeded RANDOM; carries no information about the inputs, so it is safe to
# publish in CI artefacts.
build_id="$$-${RANDOM}"

# One structured diagnostic record. Extra arguments are appended verbatim and
# are expected to be key=value.
log_event() {
    local event=$1
    shift
    printf 'build_event event=%s target=%s build_id=%s elapsed_seconds=%s' \
        "${event}" "${target_name}" "${build_id}" "${SECONDS}"
    local field
    for field in "$@"; do
        printf ' %s' "${field}"
    done
    printf '\n'
}

# Strip anything secret-bearing out of text captured from another command
# before it is logged: URL userinfo, and query strings.
redact_secrets() {
    sed -E -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/[:space:]]*@#\1REDACTED@#g' \
        -e 's#\?[^[:space:]]*#?REDACTED#g'
}

die() {
    log_event build_failed "detail=\"$*\""
    echo "$0: $*" >&2
    exit 1
}

# Remove only this invocation's own scratch: the part-downloaded tarball and
# the staging directory. Idempotent, because the INT and TERM handlers fall
# through to the EXIT handler.
#
# A <staging>.previous directory is never touched here. On the fallback path
# it is the only remaining copy of the last complete output whenever rollback
# has failed, so removing it would destroy the recovery data.
cleanup() {
    local removed_download=no removed_staging=no
    if [[ -n ${download_tmp} && -e ${download_tmp} ]]; then
        rm -f "${download_tmp}"
        removed_download=yes
    fi
    if [[ -n ${staging_dir} && -e ${staging_dir} ]]; then
        rm -rf "${staging_dir}"
        removed_staging=yes
    fi
    if [[ ${removed_download} == yes || ${removed_staging} == yes ]]; then
        log_event cleanup "removed_download=${removed_download}" \
            "removed_staging=${removed_staging}"
    fi
    download_tmp=
    staging_dir=
    return 0
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Take the activity lock shared, for the lifetime of this process. Any number
# of builds may hold it at once; scripts/clean.sh waits for all of them.
acquire_activity_lock() {
    mkdir -p "${LOCK_DIR}"
    exec {activity_fd}>"${LOCK_DIR}/activity.lock"
    "${FLOCK}" -s "${activity_fd}"
    log_event activity_lock_acquired
}

# True when $1 exists and matches the expected checksum.
checksum_matches() {
    [[ -f $1 ]] || return 1
    echo "${tarball_sha256}  $1" | "${SHA256SUM}" -c --status -
}

# Fetch the upstream tarball into the shared cache, leaving a file at
# "${cache_dir}/${tarball}" whose checksum matches ${tarball_sha256}.
#
# The cache is shared between the two targets and between concurrent runs:
# the Makefile's .NOTPARALLEL only orders targets within a single make
# process, so two make invocations (or two direct calls to this script) can
# reach here at once. Downloading to a per-invocation temporary file and
# publishing it with a single rename keeps that safe — concurrent runs
# cannot truncate each other's download or expose a partial file under the
# final name. Reuse is gated on the checksum rather than on mere presence,
# so a file left behind by an interrupted run is re-fetched instead of
# failing the build.
fetch_tarball() {
    mkdir -p "${cache_dir}"

    if checksum_matches "${cache_dir}/${tarball}"; then
        log_event cache_hit "tarball=${tarball}"
        return
    fi
    log_event cache_miss "tarball=${tarball}"

    # The URL is never logged: it is overridable and may carry userinfo or a
    # query token. The filename is enough to identify what is being fetched.
    log_event download_start "tarball=${tarball}"
    download_tmp=$(mktemp "${cache_dir}/${tarball}.XXXXXX")
    local curl_stderr
    if ! curl_stderr=$("${CURL}" -fsSL -o "${download_tmp}" "${tarball_url}" 2>&1 >/dev/null); then
        die "download of ${tarball} failed: $(redact_secrets <<<"${curl_stderr}" | tr '\n' ' ')"
    fi
    if ! checksum_matches "${download_tmp}"; then
        log_event checksum_failed "tarball=${tarball}"
        die "checksum mismatch for downloaded ${tarball}"
    fi
    mv -f "${download_tmp}" "${cache_dir}/${tarball}"
    download_tmp=
    log_event cache_published "tarball=${tarball}"
}

# Build the spec against the cached tarball inside a throwaway container,
# writing the packages to a staging directory owned by this invocation. The
# published directory is deliberately not mounted: nothing outside this
# script ever sees a half-populated output directory.
build_in_container() {
    mkdir -p "${STAGING_ROOT}"
    staging_dir=$(mktemp -d "${STAGING_ROOT}/${target_name}.XXXXXX")
    log_event staging_created

    log_event container_build_start
    # The single-quoted script below is expanded by the container's shell,
    # not this one, so its ${...} references must survive unexpanded.
    # shellcheck disable=SC2016
    if ! "${PODMAN}" run --rm \
        -v "${repo_root}/bash-completion.spec:/work/bash-completion.spec:ro,z" \
        -v "${cache_dir}/${tarball}:/work/${tarball}:ro,z" \
        -v "${staging_dir}:/out:z" \
        "${image}" \
        bash -c '
            set -euo pipefail
            dnf -y install rpm-build make
            topdir=/work/rpmbuild
            mkdir -p "${topdir}/SOURCES"
            cp /work/*.tar.xz "${topdir}/SOURCES/"
            rpmbuild --define "_topdir ${topdir}" -ba /work/bash-completion.spec
            mkdir -p /out/srpm
            cp "${topdir}"/RPMS/noarch/*.rpm /out/
            cp "${topdir}"/SRPMS/*.src.rpm /out/srpm/
            ls -l /out /out/srpm
        '; then
        log_event container_build_failed
        die "the container build for ${target_name} failed; see the output above"
    fi
}

# Refuse to publish anything but a complete set. A build that produced only
# some of its packages must leave the previous output in place rather than
# replace it with something the tmt plans and the release job would then
# treat as the build's full result.
validate_staging() {
    local base devel srpm missing=()

    base=$(find "${staging_dir}" -maxdepth 1 -type f \
        -name 'bash-completion-[0-9]*.rpm' ! -name '*-devel-*' | wc -l || true)
    devel=$(find "${staging_dir}" -maxdepth 1 -type f \
        -name 'bash-completion-devel-*.rpm' | wc -l || true)
    srpm=$(find "${staging_dir}/srpm" -maxdepth 1 -type f \
        -name '*.src.rpm' 2>/dev/null | wc -l || true)

    [[ ${base} -ge 1 ]] || missing+=('the base package')
    [[ ${devel} -ge 1 ]] || missing+=('the -devel subpackage')
    [[ ${srpm} -ge 1 ]] || missing+=('the source RPM')

    if [[ ${#missing[@]} -ne 0 ]]; then
        log_event validation_failed "base=${base}" "devel=${devel}" \
            "srpm=${srpm}" "detail=\"missing ${missing[*]}\""
        die "incomplete build for ${target_name}, missing: ${missing[*]}"
    fi
    log_event validation_ok "base=${base}" "devel=${devel}" "srpm=${srpm}"
}

# Replace the published directory with the staged one under an exclusive
# per-target lock.
#
# `mv -T --exchange` (renameat2 RENAME_EXCHANGE) swaps the two directories in
# one atomic step, so a reader of <outdir> sees either the whole previous set
# or the whole new one. Hosts without it — coreutils older than 9.5, or a
# filesystem that does not implement the call — take the fallback path, which
# is NOT atomic: it moves the previous output aside and then moves staging
# into place, so <outdir> is briefly absent during a normal swap. No partial
# or mixed set is ever visible either way.
#
# If the fallback's promotion fails, the previous output is rolled back into
# place and the build exits non-zero. If the rollback itself fails, the build
# still exits non-zero and the previous complete output is left at
# <staging>.previous, which cleanup deliberately does not remove.
publish_staging() {
    local published_fd previous fallback_reason
    mkdir -p "${LOCK_DIR}" "$(dirname "${outdir_path}")"
    exec {published_fd}>"${LOCK_DIR}/publish-${target_name}.lock"
    "${FLOCK}" -x "${published_fd}"
    log_event publication_lock_acquired

    if [[ ! -e ${outdir_path} ]]; then
        # First publication: a plain rename into a free name is atomic.
        mv -T "${staging_dir}" "${outdir_path}"
        log_event published mode=first
        exec {published_fd}>&-
        return
    fi

    if [[ ${PUBLISH_EXCHANGE} != never ]] &&
        mv -T --exchange "${staging_dir}" "${outdir_path}" 2>/dev/null; then
        # staging_dir now holds the superseded set; cleanup drops it.
        log_event published mode=exchange
        exec {published_fd}>&-
        return
    fi

    if [[ ${PUBLISH_EXCHANGE} == never ]]; then
        fallback_reason=exchange_disabled
    else
        fallback_reason=exchange_unsupported
    fi

    previous="${staging_dir}.previous"
    mv -T "${outdir_path}" "${previous}" ||
        die "could not move the previous output of ${target_name} aside"

    if "${PUBLISH_MV}" -T "${staging_dir}" "${outdir_path}"; then
        rm -rf "${previous}"
        log_event published mode=fallback "fallback_reason=${fallback_reason}"
        exec {published_fd}>&-
        return
    fi

    log_event publish_fallback_failed "fallback_reason=${fallback_reason}"
    log_event rollback_start "recoverable_path=${previous}"
    if "${PUBLISH_MV}" -T "${previous}" "${outdir_path}"; then
        log_event rollback_ok
        exec {published_fd}>&-
        die "publication of ${target_name} failed; the previous complete output has been restored"
    fi

    log_event rollback_failed "recoverable_path=${previous}"
    exec {published_fd}>&-
    die "publication of ${target_name} failed and the rollback failed; the previous complete output is preserved at ${previous}"
}

# Test-only seam. Announces that this build has staged and validated a
# complete set and is about to contend for the publication lock, then blocks
# until released. It is inert unless PREPUBLISH_ANNOUNCE_FIFO is set, which
# no real build sets, and it changes nothing else: the activity lock is still
# held and the staged output is still unpublished while it waits. It exists
# so scripts/tests/test-build-rpm.sh can hold two builds of the same target
# at exactly this point and then release them into the publication lock
# together.
prepublish_barrier() {
    [[ -n ${PREPUBLISH_ANNOUNCE_FIFO:-} ]] || return 0
    echo staged >"${PREPUBLISH_ANNOUNCE_FIFO}"
    [[ -n ${PREPUBLISH_WAIT_FIFO:-} ]] || return 0
    read -r _ <"${PREPUBLISH_WAIT_FIFO}"
}

acquire_activity_lock
fetch_tarball
build_in_container
validate_staging
prepublish_barrier
publish_staging

log_event build_complete
echo "RPMs written to ${outdir}"
