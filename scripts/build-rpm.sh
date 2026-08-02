#!/usr/bin/env bash
# Build the bash-completion RPM inside a podman container for a given target.
#
# Usage: scripts/build-rpm.sh <image> <outdir>
#   <image>   container image to build in (e.g. registry.fedoraproject.org/fedora:43)
#   <outdir>  directory to place the built RPMs in (relative to the repo root)
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <image> <outdir>" >&2
    exit 2
fi

image=$1
outdir=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version=2.18.0
tarball="bash-completion-${version}.tar.xz"
tarball_url="https://github.com/scop/bash-completion/releases/download/${version}/${tarball}"
tarball_sha256=88bcf85124f77f74f2f2f8bcd16ac4382d807a827ede742a64940c7116aea33f

cache_dir="${repo_root}/.build"

die() {
    echo "$0: $*" >&2
    exit 1
}

# True when $1 exists and matches the expected checksum.
checksum_matches() {
    [[ -f $1 ]] || return 1
    echo "${tarball_sha256}  $1" | sha256sum -c --status -
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
    local tmp
    tmp=$(mktemp "${cache_dir}/${tarball}.XXXXXX")
    # shellcheck disable=SC2064  # expand tmp now: it is gone by trap time
    trap "rm -f '${tmp}'" EXIT
    curl -fsSL -o "${tmp}" "${tarball_url}"
    checksum_matches "${tmp}" ||
        die "checksum mismatch for downloaded ${tarball}"
    mv -f "${tmp}" "${cache_dir}/${tarball}"
    trap - EXIT
}

# Build the spec against the cached tarball inside a throwaway container,
# copying the resulting packages out to ${outdir}.
build_in_container() {
    mkdir -p "${repo_root}/${outdir}"

    podman run --rm \
        -v "${repo_root}/bash-completion.spec:/work/bash-completion.spec:ro,z" \
        -v "${cache_dir}/${tarball}:/work/${tarball}:ro,z" \
        -v "${repo_root}/${outdir}:/out:z" \
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

fetch_tarball
build_in_container

echo "RPMs written to ${outdir}"
