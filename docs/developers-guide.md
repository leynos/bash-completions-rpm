# Developer's guide

This guide covers the repository layout, build and test architecture, and
CI/release workflow for people working on the packaging itself. For
installing the built packages, see the [user's guide](users-guide.md).

______________________________________________________________________

## Requirements

The host needs:

- `podman` (builds and tests run in containers)
- `tmt` >= 1.38
- `curl` (fetches the upstream release tarball)
- `sha256sum` (coreutils; verifies the tarball checksum)
- `make`

Container provisioning needs `tmt` installed with its container
extra, `tmt[provision-container]`; CI installs it with
`pipx install 'tmt[provision-container]'`.

The test containers themselves need further packages — `tar`,
`util-linux`, `/usr/bin/script` and `/usr/bin/ps` for `functional`;
`/usr/bin/pkg-config` for `smoke`; and `rpmlint` for `rpmlint`, on
Fedora only. These come from each test's `require:` metadata in its
`main.fmf` and are installed into the provisioned guest by `tmt`
itself; none of them is installed by a developer on the host. Rocky
Linux 10 disables the `rpmlint` test: `tests/rpmlint/main.fmf` carries
an `adjust` rule that sets `enabled: false` when `distro == rocky-10`,
because `rpmlint` is not in Rocky's base repositories.

______________________________________________________________________

## Repository layout

- `bash-completion.spec`: the RPM spec, based on the Fedora rawhide spec
  with distribution patches dropped and the dejagnu test machinery
  removed.
- `scripts/build-rpm.sh`: builds the RPMs for one target inside a podman
  container.
- `scripts/clean.sh`: removes build output and the cached tarball,
  serialized against builds. Run via `make clean`.
- `scripts/tests/test-build-rpm.sh`: host-side unit tests for
  `build-rpm.sh` and `scripts/clean.sh`, run via `make unit`.
- `scripts/tests/model_check.py`: a bounded state-space check of the
  same build, publication and cleanup machine, also run via
  `make unit`.
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

`scripts/build-rpm.sh <image> <outdir>` builds the RPM for one target
and publishes it atomically. It is organized into five functions,
called in order from the bottom of the script: `acquire_activity_lock`,
`fetch_tarball`, `build_in_container`, `validate_staging`, and
`publish_staging`.

1. `acquire_activity_lock` takes `.build/locks/activity.lock` shared
   for the lifetime of the script, so `scripts/clean.sh` (which takes
   the same lock exclusively) never runs while a build is active.
2. `fetch_tarball` downloads the upstream
   `bash-completion-2.18.0.tar.xz` release tarball into `.build/`.
   Reuse of a cached file is checksum-gated: it is verified against a
   sha256 pinned in the script rather than merely checked for
   existence, so a truncated or corrupt file left behind by an
   interrupted run is re-fetched instead of failing the build. Each
   download goes to a per-invocation `mktemp` file inside `.build/`
   and is published to the final name with a single atomic rename; an
   `EXIT` trap removes the temporary file on failure. This makes the
   cache safe for concurrent invocations to share: two `make` runs, or
   two direct calls to the script, can reach the download at the same
   time.
3. `build_in_container` runs `podman run` against the given container
   image, mounting the spec and the cached tarball read-only, and a
   fresh per-invocation staging directory at `/out`. The staging
   directory is created with `mktemp -d` under `dist/.staging/`
   (`STAGING_ROOT`, which defaults to a `.staging` directory beside
   the published one, so promotion is a rename within one filesystem).
   Inside the container it installs `rpm-build` and `make`, runs
   `rpmbuild -ba` against the spec, and copies the freshly built
   binary RPMs and SRPM into the staging directory. The published
   `<outdir>` is deliberately never mounted into the container, so
   nothing outside the script ever observes a half-populated output
   directory.
4. `validate_staging` refuses to publish an incomplete set: it
   requires at least one base package, one `-devel` subpackage, and
   one source RPM under `srpm/` in the staging directory, and names
   whatever is missing otherwise. A build that produced only some of
   its packages leaves the previously published output untouched.
5. `publish_staging` replaces `<outdir>` with the staging directory
   under an exclusive per-target lock,
   `.build/locks/publish-<target>.lock`, so two builds of the same
   target cannot interleave their swaps. `mv -T --exchange` (the
   `renameat2` `RENAME_EXCHANGE` call) swaps the staging and published
   directories in one atomic step, so a reader of `<outdir>` sees
   either the whole previous set or the whole new set. First
   publication, where `<outdir>` does not yet exist, is a plain
   `mv -T` rename, also atomic. Hosts without `RENAME_EXCHANGE` —
   coreutils older than 9.5, or a filesystem that does not implement
   the call — fall back to moving the old directory aside and then
   moving the new one in. GitHub's `ubuntu-24.04` runners ship
   coreutils 9.4 and therefore take the fallback path. This fallback
   is **not** atomic: `<outdir>` is briefly absent between the two
   moves of a normal swap, though no partial or mixed set is ever
   visible on either path. If the fallback's promotion move fails,
   the previous output is rolled back into place and the build exits
   non-zero. If the rollback itself also fails, the build still exits
   non-zero, `<outdir>` is left absent, and the previous complete
   output is preserved at `<staging>.previous`, which `cleanup`
   deliberately never removes; the failure message names that
   recoverable path. A `PUBLISH_MV` seam is used for exactly these two
   moves — promotion and rollback — and nothing else, defaulting to
   `mv`, so a test stub can inject a failure into either move without
   disturbing the script's other renames.

An `EXIT`/`INT`/`TERM` trap removes only this invocation's own
scratch on cancellation or failure — the part-downloaded tarball and
the staging directory — releasing its locks as the corresponding file
descriptors close.

### Ownership

- `.build/`: the checksum-verified upstream tarball cache, plus
  `.build/locks/`. Shared by every target and every concurrent
  invocation; owned by no single build.
- `dist/<target>/`: published output, only ever replaced whole by the
  publish step.
- `dist/.staging/`: per-invocation staging directories, each owned by
  exactly one invocation, which removes its own on exit.
- `make clean` runs `scripts/clean.sh`, which removes `dist/` and the
  cached tarball but deliberately keeps `.build/locks/` — removing a
  lock file while holding a lock on it would let a waiting process
  lock the unlinked inode and proceed as though it held exclusive
  access.

### Locking

- `.build/locks/activity.lock` is held shared by `build-rpm.sh` for
  its whole run; `scripts/clean.sh` takes the same lock exclusively,
  so `clean` waits for in-flight builds and no build can start while
  it is removing things. That is what stops `clean` deleting output
  or cache a build is using.
- `.build/locks/publish-<target>.lock` is held exclusively across the
  publish step, so two builds of the same target cannot interleave
  their swaps.

### Diagnostics

Every lifecycle step writes a single-line `key=value` record to
stdout, prefixed `build_event`, so a CI log can be grepped or parsed.
Every record carries `event`, `target`, `build_id` and
`elapsed_seconds`; a free-form `detail="..."` field, when present, is
always last. `build_id` is derived from the pid and bash's `RANDOM`
and carries no information about the inputs, so it is safe to publish
in CI artefacts.

The events logged across the lifecycle are `activity_lock_acquired`,
`cache_hit`, `cache_miss`, `download_start`, `checksum_failed`,
`cache_published`, `staging_created`, `container_build_start`,
`container_build_failed`, `validation_ok` and `validation_failed`
(both with `base=`, `devel=` and `srpm=` counts),
`publication_lock_acquired`, `published` (with
`mode=first|exchange|fallback` and, on the fallback path,
`fallback_reason=exchange_disabled|exchange_unsupported`),
`publish_fallback_failed`, `rollback_start`, `rollback_ok`,
`rollback_failed`, `build_complete`, `cleanup`, and `build_failed`
(emitted by `die`, carrying the failure detail).

`TARBALL_URL` is overridable and may carry userinfo or a query token,
so it is never logged, in whole or in part: downloads are identified
by tarball filename only, and any diagnostic text captured from
`curl` passes through a `redact_secrets` helper that strips URL
userinfo and query strings before it is logged. This is what makes
the CI log safe to upload as an artefact.

This reworking is transparent at the command level: `make rpms`,
`make test`, `make test-fedora-43`, `make test-rocky-10` and
`make clean` all behave as before from a developer's point of view.

Every external command the script invokes (`curl`, `sha256sum`,
`podman`, `flock`) and every pinned or configurable input (`VERSION`,
`TARBALL_URL`, `TARBALL_SHA256`, `CACHE_DIR`, `LOCK_DIR`,
`STAGING_ROOT`, `PUBLISH_EXCHANGE`, `PUBLISH_MV`) can be overridden
from the environment, each via a `: "${NAME:=default}"` seam. Real
builds override none of them; the seams exist so
`scripts/tests/test-build-rpm.sh` and `scripts/tests/model_check.py`
can drive the script against stub commands and a local fixture, with
no network or container runtime.
`PUBLISH_EXCHANGE=never` forces the fallback publication path, which
the unit tests use to exercise it on any host regardless of the
host's coreutils version. `<outdir>` is normally resolved relative to
the repository root, but an absolute path is taken as given — the
unit tests use that to write outside the checkout.

`scripts/clean.sh` has an analogous set of seams: `FLOCK`,
`CACHE_DIR`, `LOCK_DIR`, `DIST_DIR`, and a test-only
`CLEAN_PRELOCK_HOOK` that the unit suite uses to observe the script
waiting on the activity lock without a timing sleep.

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

`make unit` runs two checks in order. First,
`scripts/tests/test-build-rpm.sh`, a host-side suite of 18 cases that
exercises `build-rpm.sh`'s and `scripts/clean.sh`'s own validation,
orchestration and locking — argument checking, cache reuse and
re-fetch, checksum enforcement, the `podman` invocation's mounts,
atomic publication on both the exchange and the fallback path,
refusal to publish an incomplete build, two concurrent builds of the
same target, `clean` waiting for an in-flight build, failed and
cancelled builds leaving no staging directories, temporary files or
held locks behind, a secret-bearing tarball URL staying out of the
build log, the structured diagnostic events, and fallback rollback on
both a successful and a failed rollback — against stub commands and a
local fixture. Its concurrency cases are driven by FIFO handshakes
rather than timing sleeps, so they are deterministic; the suite needs
neither a network nor a real podman runtime. Second,
`scripts/tests/model_check.py` runs (see
[Bounded state-space check](#bounded-state-space-check) below).

The concurrent-build case holds two builds of one target at a
test-only barrier just before publication, `prepublish_barrier`,
which is inert unless `PREPUBLISH_ANNOUNCE_FIFO` is set and so never
runs in a real build. With both staged and validated, the test takes
the target's publication lock itself and then releases both builds
into it. Neither can publish while that lock is held, which is what
makes the assertion that the published directory is still exactly the
previous complete set a statement about the lock rather than about
timing. Once the test drops the lock, one build publishes and the
other follows; which of the two wins is deliberately not asserted,
only that the result is one complete generation and that no staging
directory, temporary file or held lock survives.

### Bounded state-space check

`scripts/tests/model_check.py` sweeps the same build, publication and
cleanup machine that `test-build-rpm.sh` exercises with fixed cases.
It is a **bounded check, not a proof**: it samples a finite, seeded
set of cases and interleavings, so a pass demonstrates the absence of
a violation across whatever it sampled, not correctness for every
possible input.

It has two layers. An **executed** layer drives the real
`build-rpm.sh` and `clean.sh` through stub commands and FIFOs, over
generated combinations of cache state (absent, valid, corrupt,
interrupted download), build outcome (success, partial, container
failure, cancellation), publication mode (first, exchange, fallback,
fallback promotion failure, rollback failure) and clean position
(none, before, after). An **abstract** layer models the same algorithm
as a small transition system and samples interleavings of up to two
concurrent builds and a clean, covering combinations — arbitrary
interleavings of two builds' internal steps against a clean — that
cannot be driven directly. The abstract layer checks the algorithm,
not the shell code; the executed layer checks the shell code as
written.

The check is deterministic from an explicit seed, printed on every
run and repeated alongside the offending case on failure. The seed
and case counts are overridable: `--seed`/`MODEL_CHECK_SEED`,
`--executed-cases`/`MODEL_CHECK_EXECUTED` and
`--schedules`/`MODEL_CHECK_SCHEDULES`. It uses only the Python
standard library and needs neither a network nor a container runtime.

Its four invariants, stated in the module's docstring, are:

- an observable published output is either absent only in the
  documented cases, or exactly one complete generation — never
  partial or mixed;
- `clean` never removes output or cache while an activity lock is
  held;
- a successful rollback restores the prior complete output;
- a failed or cancelled invocation leaves no invocation-owned staging
  directory, temporary tarball or held lock.

The deterministic FIFO cases in `test-build-rpm.sh` remain regression
tests for specific past defects; the model check is a breadth sweep
over their state space, not a replacement for them.

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

`syntax`, `functional`, and `upgrade` each assert an invariant, but
layer their checks differently depending on how large the input space
is and whether a single deployment fact is what is actually at risk:

- **Completion-file validity.** `syntax` enumerates every completion
  file the installed RPM actually ships, from `rpm -ql`'s own manifest,
  and checks all 1,091 of them — the whole population, not a sample —
  so there is no remaining input space for a property test to explore.
  The `>400` assertion in that test is a sanity floor guarding against
  the selector silently matching nothing; it is not the invariant being
  tested. Each file's sourcing check is normalized to a documented
  exit-status set — 0 (sourced cleanly) and 1 (sourced and returned
  non-zero, which is permitted, since many completions bail out early
  when their command is not installed) are the only accepted
  outcomes; anything else is treated as an environmental, I/O or
  sourcing failure, and every failure is reported with the file path,
  exit status and captured output.
- **Completion robustness.** `functional` pins a handful of concrete
  cases (`kill -`, `tar --`, and `umount` followed by a trailing
  space, producing real `COMPREPLY` output), then adds a bounded
  property check over a matrix of five commands (`tar`, `kill`,
  `umount`, `chmod`, `grep`) and seven current-word prefixes (empty,
  `-`, `--`, `--ex`, `/`, a non-existent path, and a word matching
  nothing), asserting that no completion function ever exits with an
  unexpected status or writes to stderr, whatever partial word it is
  handed.
- **EVR ordering.** The invariant that matters is not that
  `rpm.vercmp` is a correct total order over arbitrary EVR pairs — that
  is upstream `rpm`'s own property, and it is tested there — but that
  the specific EVR this repository ships sorts above whatever the
  distribution's repositories currently offer. `upgrade` asserts that
  against the real distro repository metadata inside the container,
  using `rpm`'s own comparison function. That candidate is selected
  with `dnf repoquery --latest-limit=1`, which orders by RPM version
  rather than lexically — a lexical `sort` would rank `2.9` above
  `2.10`; more than one line coming back instead fails the EVR
  character-pattern check below loudly, rather than being silently
  narrowed. A failure of the `dnf repoquery` call itself — as opposed
  to an empty or unexpected result — is reported with its captured
  stderr and exit status and fails the test outright, rather than
  being read as "no candidate". It adds a bounded property check
  against 13 representative
  older EVRs (epoch-less el7/el8/el9
  forms, epoch-1 el10 and fc forms, a bare `1:2.18.0-1`, a pre-release
  `0.1.rc1` release, and a `~rc1` tilde version). Each pair is compared
  in both directions, so a comparison that silently returned 0 could
  not pass.

The two EVR strings used in the live comparison are validated against
a conservative character pattern before being interpolated into the
`rpm --eval "%{lua:...}"` expression, so the generated expression's
quoting is well defined, and malformed query output fails loudly rather
than silently.

______________________________________________________________________

## Makefile dependency graph

```text
test  → test-fedora-43 → rpm-fedora-43
                       → unit
      → test-rocky-10  → rpm-rocky-10
                       → unit

rpms  → rpm-fedora-43
      → rpm-rocky-10
```

Each `test-<target>` target depends on `rpm-<target>` and on `unit`, so
a single `make test-<target>` invocation builds the RPMs, runs the
host-side unit suite, and then runs the `tmt` plan against them (this
is what CI uses). Both `test-*` targets depend on `unit`, but `make`
runs it only once per invocation, even for a single-target run. The
Makefile declares `.NOTPARALLEL` because the `test-*` targets share
podman resources and parallel `make` would race on them.
`.NOTPARALLEL` only orders targets within a single `make` process,
though; cross-process safety no longer depends on it. The `.build/`
tarball cache shared by the `rpm-*` targets is protected
independently, by `fetch_tarball`'s checksum-gated reuse and atomic
rename, and published output is protected by `publish_staging`'s
per-target lock and atomic swap (see [Build flow](#build-flow)), so
separate `make` invocations, or direct script calls, racing on the
same cache entry or output directory remain safe.

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
for each (which builds the RPMs and then the `tmt` plan). That step
tees its output to `build-<target>.log`, with `set -o pipefail` so the
step's exit status is `make`'s rather than `tee`'s. On failure, the
"Upload build diagnostics on failure" step uploads that log together
with the `tmt` logs as a single `diagnostics-<target>` artefact
(renamed from `tmt-logs-<target>`); this is safe to upload because
`build-rpm.sh` never logs the tarball URL or any other secret-bearing
input (see [Diagnostics](#diagnostics)). On success or failure it also
uploads the built RPMs as artefacts. A `concurrency` group keyed on
the workflow and ref cancels superseded runs of the same branch or PR.
The workflow requests only `contents: read` permission.

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
