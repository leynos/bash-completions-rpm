# 🐚 bash-completions-rpm

*Fresh bash-completion 2.18.0 RPMs for Fedora 43 and Rocky Linux 10.*

The official packages lag well behind upstream. This project rebuilds
[bash-completion 2.18.0](https://github.com/scop/bash-completion/releases/tag/2.18.0)
for both distributions and tests the result properly — in containers, with
`tmt`, before it goes anywhere near your shell.

______________________________________________________________________

## Why bash-completions-rpm?

- **Current completions**: Fedora 43 ships 2.16, while Rocky Linux 10 ships
  an older release still; upstream 2.18.0 brings hundreds of new and fixed
  completions.
- **Safe upgrade path**: the spec keeps `Epoch: 1` and follows Fedora's
  conflict removals, so it installs over the distro package and is never
  silently superseded by it.
- **Actually tested**: every build is installed into a pristine container
  and exercised — real `<TAB>` presses, real `COMPREPLY` output, all 1,091
  completion files parsed and sourced.
- **No host pollution**: the heavy lifting — `rpmbuild`, test guests —
  happens inside podman containers; the host needs only a handful of
  standard tools.

______________________________________________________________________

## Quick start

### Requirements

- podman (builds and tests run in containers)
- tmt ≥ 1.38
- curl (fetches the upstream release tarball)
- sha256sum (coreutils; verifies the tarball checksum)
- make

### Build and test

```shell
# Build RPMs for both targets
make rpms

# dist/fedora-43/bash-completion-2.18.0-1.fc43.noarch.rpm
# dist/rocky-10/bash-completion-2.18.0-1.el10.noarch.rpm
# (plus -devel subpackages, and SRPMs under dist/<target>/srpm/)

# Run the full test suite, one podman container per plan
make test
```

### Install

```shell
sudo dnf install ./dist/fedora-43/bash-completion-2.18.0-1.fc43.noarch.rpm
```

______________________________________________________________________

## Features

- Spec derived from Fedora rawhide, with distribution patches dropped
  (none apply to 2.18.0) and the dejagnu test machinery removed.
- Containerized builds via `scripts/build-rpm.sh`, with the upstream
  tarball pinned by sha256.
- One `tmt` plan per target, each provisioning a podman container and
  installing the freshly built RPMs before testing:

| Test                | What it checks                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------- |
| `/tests/smoke`      | EVR (incl. epoch), `rpm -V` integrity, payload, profile.d behaviour, pkg-config/cmake devel files |
| `/tests/functional` | Dynamic loader registration, on-demand `_comp_load`, real `COMPREPLY` for `kill -` and `tar --`   |
| `/tests/syntax`     | All 1,091 completion files parse and source cleanly                                               |
| `/tests/upgrade`    | `dnf upgrade` cannot replace the local build                                                      |
| `/tests/rpmlint`    | Zero rpmlint errors (Fedora only)                                                                 |

______________________________________________________________________

## Notes

- The Makefile sets `NETAVARK_FW=none` for tmt runs: netavark's nftables
  rules fail on WSL2 kernels, and the firewall is unnecessary for
  rootless test containers.
- VM-based testing (`tmt provision --how virtual`) is a planned
  follow-up; container coverage comes first.

______________________________________________________________________

## Licence

The packaged software and the spec are GPL-2.0-or-later, matching
upstream [bash-completion](https://github.com/scop/bash-completion).

______________________________________________________________________

## Contributing

Contributions welcome! Open an issue or pull request — and please run
`make test` before submitting.
