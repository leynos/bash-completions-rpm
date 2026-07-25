# bash-completion 2.18.0 RPMs for Fedora 43 and Rocky Linux 10

Packaging for [bash-completion 2.18.0](https://github.com/scop/bash-completion/releases/tag/2.18.0),
rebuilt for distributions whose official RPMs lag behind upstream. The spec is
derived from the Fedora rawhide spec, with distribution patches dropped (none
apply to 2.18.0). The package keeps `Epoch: 1` so upgrade paths against the
distro packages behave correctly.

## Requirements

- podman (builds run in containers; tests use the tmt container provisioner)
- tmt >= 1.38

## Building

```console
make rpms            # both targets
make rpm-fedora-43   # dist/fedora-43/
make rpm-rocky-10    # dist/rocky-10/
```

The build script downloads the upstream tarball (sha256-pinned) into
`.build/`, then runs `rpmbuild` inside the matching distribution container.
Binary RPMs land in `dist/<target>/`, the SRPM in `dist/<target>/srpm/`.

## Testing

```console
make test            # both plans, sequentially
make test-fedora-43
make test-rocky-10
```

Each tmt plan provisions a podman container, installs the freshly built RPMs
from `dist/<target>/`, and runs the test suite:

| Test                | What it checks                                                        |
| ------------------- | --------------------------------------------------------------------- |
| `/tests/smoke`      | EVR (incl. epoch), `rpm -V` integrity, payload, profile.d behaviour, pkg-config/cmake devel files |
| `/tests/functional` | Default dynamic loader registration, on-demand `_comp_load`, real `COMPREPLY` output for `kill -`, `tar --`, path completion |
| `/tests/syntax`     | All ~1091 shipped completion files parse (`bash -O extglob -n`) and source cleanly under the loader |
| `/tests/upgrade`    | `dnf upgrade` against distro repos does not replace the local build   |
| `/tests/rpmlint`    | Zero rpmlint errors (Fedora only; rpmlint is absent from Rocky repos) |

`NETAVARK_FW=none` is set by the Makefile because netavark's nftables rules
fail on WSL2 kernels; the firewall is unnecessary for these rootless
containers.

VM-based testing (tmt `provision --how virtual`) is a possible follow-up.
