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
mkdir -p "${cache_dir}"

if [[ ! -f "${cache_dir}/${tarball}" ]]; then
    echo "Downloading ${tarball_url}"
    curl -fsSL -o "${cache_dir}/${tarball}.tmp" "${tarball_url}"
    mv "${cache_dir}/${tarball}.tmp" "${cache_dir}/${tarball}"
fi
echo "${tarball_sha256}  ${cache_dir}/${tarball}" | sha256sum -c -

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

echo "RPMs written to ${outdir}"
