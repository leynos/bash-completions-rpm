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

die() {
    echo "$0: $*" >&2
    exit 1
}

# Remove only this invocation's own scratch: the part-downloaded tarball and
# the staging directory. Idempotent, because the INT and TERM handlers fall
# through to the EXIT handler.
cleanup() {
    [[ -n ${download_tmp} ]] && rm -f "${download_tmp}"
    [[ -n ${staging_dir} ]] && rm -rf "${staging_dir}"
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
        return
    fi

    echo "Downloading ${tarball_url}"
    download_tmp=$(mktemp "${cache_dir}/${tarball}.XXXXXX")
    "${CURL}" -fsSL -o "${download_tmp}" "${tarball_url}"
    checksum_matches "${download_tmp}" ||
        die "checksum mismatch for downloaded ${tarball}"
    mv -f "${download_tmp}" "${cache_dir}/${tarball}"
    download_tmp=
}

# Build the spec against the cached tarball inside a throwaway container,
# writing the packages to a staging directory owned by this invocation. The
# published directory is deliberately not mounted: nothing outside this
# script ever sees a half-populated output directory.
build_in_container() {
    mkdir -p "${STAGING_ROOT}"
    staging_dir=$(mktemp -d "${STAGING_ROOT}/${target_name}.XXXXXX")

    # The single-quoted script below is expanded by the container's shell,
    # not this one, so its ${...} references must survive unexpanded.
    # shellcheck disable=SC2016
    "${PODMAN}" run --rm \
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
        '
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

    [[ ${#missing[@]} -eq 0 ]] ||
        die "incomplete build for ${target_name}, missing: ${missing[*]}"
}

# Replace the published directory with the staged one under an exclusive
# per-target lock. `mv -T --exchange` (renameat2 RENAME_EXCHANGE) swaps the
# two directories in one atomic step, so a reader of <outdir> sees either the
# whole previous set or the whole new one. Hosts without it — coreutils older
# than 9.5, or a filesystem that does not implement the call — fall back to
# moving the old directory aside first, which leaves a brief window in which
# <outdir> does not exist. Even then no partial set is ever visible.
publish_staging() {
    local published_fd
    mkdir -p "${LOCK_DIR}" "$(dirname "${outdir_path}")"
    exec {published_fd}>"${LOCK_DIR}/publish-${target_name}.lock"
    "${FLOCK}" -x "${published_fd}"

    if [[ ! -e ${outdir_path} ]]; then
        # First publication: a plain rename into a free name is atomic.
        mv -T "${staging_dir}" "${outdir_path}"
    elif [[ ${PUBLISH_EXCHANGE} != never ]] &&
        mv -T --exchange "${staging_dir}" "${outdir_path}" 2>/dev/null; then
        # staging_dir now holds the superseded set; cleanup drops it.
        :
    else
        local previous="${staging_dir}.previous"
        mv -T "${outdir_path}" "${previous}"
        mv -T "${staging_dir}" "${outdir_path}"
        rm -rf "${previous}"
    fi

    exec {published_fd}>&-
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

echo "RPMs written to ${outdir}"
