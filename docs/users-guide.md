# User's guide

This guide covers installing and using the bash-completion packages built
by this repository. For an overview of the project, see the main
[README](../README.md).

______________________________________________________________________

## What's in the packages

The packages are a rebuild of upstream
[bash-completion 2.18.0](https://github.com/scop/bash-completion/releases/tag/2.18.0)
for Fedora 43 and Rocky Linux 10, based on the Fedora rawhide spec. The
spec drops the distribution patches (none apply to 2.18.0) and the
dejagnu test machinery, and carries `Epoch: 1` so the package is never
silently superseded by the distro's older `bash-completion`.

Two packages are built:

- `bash-completion`: the completion scripts, the `bash_completion` loader,
  and the `/etc/profile.d/bash_completion.sh` hook that sources it in
  interactive login shells.
- `bash-completion-devel`: pkg-config (`bash-completion.pc`) and CMake
  config files for other packages that install completions into
  `bash-completion`'s directories at build time.

A handful of completions shipped upstream are deliberately removed to
avoid conflicts with other Fedora packages that ship their own: `cowsay`
and `cowthink` (from the `cowsay` package), `makepkg` (name clash with
pacman), `prelink`, `javaws`, and `interdiff` (from `patchutils`).

______________________________________________________________________

## Installing from a release asset

Each tagged release of this repository publishes the built RPMs and
SRPMs as assets, one set per target, on the repository's Releases page.
Download the RPM for the target distribution and install it with `dnf`:

```shell
sudo dnf install ./bash-completion-2.18.0-1.fc43.noarch.rpm
```

or, on Rocky Linux 10:

```shell
sudo dnf install ./bash-completion-2.18.0-1.el10.noarch.rpm
```

Each release also publishes a `SHA256SUMS` manifest alongside the RPM
and SRPM assets. As the RPMs are unsigned, this manifest is the
integrity check available: download it into the same directory as
the downloaded RPM and run:

```shell
sha256sum -c SHA256SUMS
```

`sha256sum -c` reports a failure for any file listed in the manifest
but not downloaded, so verifying a single RPM is best done with
`sha256sum -c --ignore-missing SHA256SUMS`.

To also get the pkg-config and CMake files, install the `-devel`
subpackage alongside the base package:

```shell
sudo dnf install ./bash-completion-2.18.0-1.fc43.noarch.rpm \
    ./bash-completion-devel-2.18.0-1.fc43.noarch.rpm
```

______________________________________________________________________

## Upgrade behaviour

The spec sets `Epoch: 1`. RPM compares epoch before version, so once this
package is installed, `dnf upgrade` will not replace it with the distro's
(unepoched, older) `bash-completion` package — the local build always
compares as newer, regardless of how the upstream version numbers relate.

______________________________________________________________________

## Building and testing locally

To build the RPMs locally instead of downloading a release asset, see
the [README's Quick start](../README.md#quick-start) for the required
tools (podman, tmt, curl, sha256sum, make) and:

```shell
# Build RPMs for both targets under dist/<target>/
make rpms

# Run the full test suite, one podman container per plan
make test
```

`make rpms` downloads the upstream tarball (sha256-pinned) and runs
`rpmbuild` inside a podman container per target; `make test` installs the
freshly built RPMs into a fresh container per target and runs the `tmt`
test plans against them. See the [developer's guide](developers-guide.md)
for how the build and test steps work.
