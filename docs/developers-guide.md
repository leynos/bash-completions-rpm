# Developer's guide

This guide covers the repository layout, build and test architecture, and
CI/release workflow for people working on the packaging itself. For
installing the built packages, see the [user's guide](users-guide.md).

______________________________________________________________________

## Repository layout

- `bash-completion.spec`: the RPM spec, based on the Fedora rawhide spec
  with distribution patches dropped and the dejagnu test machinery
  removed.
- `scripts/build-rpm.sh`: builds the RPMs for one target inside a podman
  container.
- `plans/`: `tmt` plans, one per target (`fedora-43.fmf`, `rocky-10.fmf`),
  each provisioning a container and installing the freshly built RPMs
  before running the tests.
- `tests/`: the `tmt` test cases — `smoke`, `functional`, `syntax`,
  `upgrade`, and `rpmlint` — each with a `main.fmf` metadata file and a
  `test.sh` script.
- `.github/workflows/`: `ci.yml` (build and test on push/PR) and
  `release.yml` (build, test, and publish on tag push).

______________________________________________________________________

## Build flow

`scripts/build-rpm.sh <image> <outdir>` builds the RPM for one target. It
is organised into two functions, called in order from the bottom of the
script:

1. `fetch_tarball` downloads the upstream
   `bash-completion-2.18.0.tar.xz` release tarball into `.build/`.
   Reuse of a cached file is checksum-gated: it is verified against a
   sha256 pinned in the script rather than merely checked for
   existence, so a truncated or corrupt file left behind by an
   interrupted run is re-fetched instead of failing the build. Each
   download goes to a per-invocation `mktemp` file inside `.build/`
   and is published to the final name with a single atomic rename; an
   `EXIT` trap removes the temporary file on failure. This makes the
   cache safe for concurrent invocations to share: the `Makefile`'s
   `.NOTPARALLEL` only orders targets within one `make` process, so
   two `make` runs, or two direct calls to the script, can reach the
   download at the same time.
2. `build_in_container` runs `podman run` against the given container
   image, mounting the spec, the cached tarball, and the output
   directory. Inside the container it installs `rpm-build` and `make`,
   runs `rpmbuild -ba` against the spec, then copies the resulting
   binary RPMs to `<outdir>/` and the SRPM to `<outdir>/srpm/`.

The `Makefile` wires this up per target:

```makefile
rpm-fedora-43:
	scripts/build-rpm.sh $(FEDORA_IMAGE) dist/fedora-43

rpm-rocky-10:
	scripts/build-rpm.sh $(ROCKY_IMAGE) dist/rocky-10
```

`FEDORA_IMAGE` and `ROCKY_IMAGE` are pinned by digest (not just tag) for
reproducible builds; `ROCKY_IMAGE` is pulled from `quay.io` rather than
Docker Hub to avoid Docker Hub's anonymous pull rate limits on shared CI
runner IPs.

Outputs land under `dist/<target>/` — the binary RPMs directly, and the
SRPM under `dist/<target>/srpm/`.

______________________________________________________________________

## Test architecture

Each target has a `tmt` plan (`plans/fedora-43.fmf`, `plans/rocky-10.fmf`)
that:

- provisions a fresh podman container from the same digest-pinned image
  used by the corresponding `rpm-<target>` build step;
- installs the RPMs from `dist/<target>/` via the `install` prepare
  plugin;
- discovers and executes all tests under `tests/` via `discover: fmf`.

The five tests, in `tests/<name>/`:

| Test         | What it checks                                                                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `smoke`      | EVR (incl. epoch), `rpm -V` integrity, key payload paths, removed completions stay removed, `profile.d` hook behaviour, main file sources cleanly, `-devel` pkg-config/CMake files usable. |
| `functional` | `-D` dynamic loader registers; `_comp_load` loads `tar`/`kill` on demand; real `COMPREPLY` for `kill -`, `tar --`, `umount` followed by a trailing space; `-D` fallback retries (124) and registers `_comp_complete_minimal`; end-to-end interactive `<TAB>` via a `script(1)` pty completes through that fallback. |
| `syntax`     | Every shipped completion file under `completions-core/` and `completions-fallback/` (1,091 of them) is valid bash under `bash -O extglob -n`, and each one sources without error on top of the loaded `bash_completion` file. A floor of more than 400 files is asserted as a sanity guard on top of checking all of them. |
| `upgrade`    | With the local build installed, `dnf upgrade` does not replace it, and the distro's repository candidate really does compare as older via `rpm.vercmp`. |
| `rpmlint`    | `rpmlint --installed` reports no errors on either package. Disabled on Rocky Linux 10, where `rpmlint` is not available in the base repositories. |

The `functional` test's interactive fallback check requires `script(1)`
(from `util-linux`, packaged separately as `util-linux-script` on
Fedora) to provide the pty that readline needs for a real `<TAB>` press
to be observed.

### Test strategy

`syntax` and `upgrade` each assert an invariant that is deliberately
checked exhaustively rather than by property-based sampling:

- **Completion-file validity.** `syntax` enumerates every completion
  file the installed RPM actually ships, from `rpm -ql`'s own manifest,
  and checks all 1,091 of them — the whole population, not a sample —
  so there is no remaining input space for a property test to explore.
  The `>400` assertion in that test is a sanity floor guarding against
  the selector silently matching nothing; it is not the invariant being
  tested.
- **EVR ordering.** The invariant that matters is not that
  `rpm.vercmp` is a correct total order over arbitrary EVR pairs — that
  is upstream `rpm`'s own property, and it is tested there — but that
  the specific EVR this repository ships sorts above the specific
  candidate the distribution's repositories currently offer. `upgrade`
  asserts exactly that, against the real distro repository metadata
  inside the container, using `rpm`'s own comparison function.
  Generated EVR pairs would not exercise the deployment fact actually
  at risk.

Both EVR strings are validated against a conservative character
pattern before being interpolated into the `rpm --eval
"%{lua:...}"` expression, so the generated expression's quoting is
well defined and malformed query output fails loudly rather than
silently.

______________________________________________________________________

## Makefile dependency graph

```text
test  → test-fedora-43 → rpm-fedora-43
      → test-rocky-10  → rpm-rocky-10

rpms  → rpm-fedora-43
      → rpm-rocky-10
```

Each `test-<target>` target depends on `rpm-<target>`, so a single
`make test-<target>` invocation builds the RPMs and then runs the `tmt`
plan against them (this is what CI uses). The Makefile declares
`.NOTPARALLEL` because the `test-*` targets share podman resources and
parallel `make` would race on them. `.NOTPARALLEL` only orders targets
within a single `make` process, though: the `.build/` tarball cache
shared by the `rpm-*` targets is protected independently, by
`fetch_tarball`'s checksum-gated reuse and atomic rename, so separate
`make` invocations (or direct script calls) racing on the same cache
entry remain safe.

The Makefile also detects a WSL2 kernel (`grep -qi microsoft
/proc/version`) and, only in that case, runs `tmt` with
`NETAVARK_FW=none`: netavark's nftables rules fail under WSL2, and the
firewall is unnecessary for rootless test containers there. On other
hosts, including CI runners — whose older netavark rejects the `none`
backend — the default firewall driver is left alone.

______________________________________________________________________

## CI and release workflows

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests.
It matrices over `[fedora-43, rocky-10]`, running `make test-<target>`
for each (which builds the RPMs and then the `tmt` plan). On failure it
uploads the `tmt` logs; on success or failure it uploads the built RPMs
as artefacts. A `concurrency` group keyed on the workflow and ref cancels
superseded runs of the same branch or PR. The workflow requests only
`contents: read` permission.

`.github/workflows/release.yml` runs on pushes of tags matching `v*`. It
repeats the same build-and-test matrix, then a separate `release` job
(scoped to `contents: write`, the only job that needs it) downloads the
built RPM artefacts, collects every `*.rpm` file (binary and source) into
`assets/`, generates a `SHA256SUMS` manifest of those RPMs (`sha256sum --
*.rpm`, run from inside `assets/` so the manifest lists bare filenames),
and runs `gh release create`. The release title is `bash-completion
<tag>`, notes are auto-generated, and the tag name is read from the
`GITHUB_REF_NAME` environment variable rather than interpolated from
`github.ref` directly, to avoid shell injection via a crafted tag name. A
tag containing `pre`, `rc`, `alpha`, or `beta` anywhere in its name causes
the release to be created with `--prerelease`. `SHA256SUMS` is attached to
the release alongside the RPMs. All actions in both workflows are pinned
by full commit SHA, matching the container-image digest-pinning
convention above.

______________________________________________________________________

## Release process

Pushing a tag matching `v*` triggers `release.yml`. A tag such as
`v2.18.0-1`, mirroring the spec's `Version` and `Release` fields, or a
pre-release variant such as `v2.18.0-1.pre1` (which is caught by the
`pre` substring match and released as a pre-release), will build and
test both targets and then publish a GitHub release with the built RPMs
attached.

______________________________________________________________________

## Follow-up

VM-based testing (`tmt provision --how virtual`) is a planned follow-up;
container coverage comes first. See the README's Notes section.
