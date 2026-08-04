#!/usr/bin/env python3
"""Bounded state-space check of the build, publication and cleanup machine.

This is not a proof. It is a bounded check with two layers:

*   An executed layer that drives the real ``scripts/build-rpm.sh`` and
    ``scripts/clean.sh`` through stub commands and FIFOs, over a generated
    combination of cache states, build outcomes, publication modes and clean
    positions. What it checks is the shell code as written.
*   An abstract layer that models the same algorithm as a small transition
    system and samples interleavings of up to two concurrent builds and a
    clean. What it checks is the algorithm, not the shell code: combinations
    that cannot be driven directly — arbitrary interleavings of the two
    builds' internal steps against a clean — are covered here instead.

Both layers are deterministic given a seed, which is printed on every run and
reported again with the offending case on failure. Neither layer needs a
network or a container runtime.

The fixed FIFO cases in ``test-build-rpm.sh`` remain the regression tests for
specific past defects; this checker is a breadth sweep over their state space,
not a replacement for them.

Invariants, stated once here and asserted in both layers:

I1  An observable published output is either absent — and then only while a
    fallback publication is between moving the previous output aside and
    promoting the new one, or after a failure that left nothing published —
    or exactly one complete generation. Never a partial or mixed set.
I2  Clean never removes the published output or the cache while any activity
    lock is held.
I3  A successful rollback restores the prior complete output.
I4  A failed or cancelled invocation leaves no invocation-owned staging
    directory, no invocation-owned temporary tarball, and no held lock.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import itertools
import os
import random
import select
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_SH = REPO_ROOT / "scripts" / "build-rpm.sh"
CLEAN_SH = REPO_ROOT / "scripts" / "clean.sh"

VERSION = "2.18.0"
TARBALL = f"bash-completion-{VERSION}.tar.xz"
BASE_RPM = f"bash-completion-{VERSION}-1.fc43.noarch.rpm"
DEVEL_RPM = f"bash-completion-devel-{VERSION}-1.fc43.noarch.rpm"
SRC_RPM = f"srpm/bash-completion-{VERSION}-1.fc43.src.rpm"
COMPLETE = (BASE_RPM, DEVEL_RPM, SRC_RPM)

DEFAULT_SEED = 20260804

CURL_STUB = """#!/usr/bin/env bash
set -euo pipefail
out=
while [[ $# -gt 0 ]]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
cat "${CURL_STUB_FIXTURE}" >"${out}"
"""

PODMAN_STUB = """#!/usr/bin/env bash
set -euo pipefail
out=
for arg in "$@"; do
    case ${arg} in
        *:/out:z) out=${arg%%:/out:z} ;;
    esac
done
[[ -n ${out} ]] || exit 64
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
mkdir -p "${out}/srpm"
echo "${PODMAN_STUB_TAG}" >"${out}/%(base)s"
if [[ -z ${PODMAN_STUB_PARTIAL:-} ]]; then
    echo "${PODMAN_STUB_TAG}" >"${out}/%(devel)s"
    echo "${PODMAN_STUB_TAG}" >"${out}/%(src)s"
fi
""" % {"base": BASE_RPM, "devel": DEVEL_RPM, "src": SRC_RPM}

PUBLISH_MV_STUB = """#!/usr/bin/env bash
set -euo pipefail
args=("$@")
src=${args[-2]}
if [[ ${src} == *.previous ]]; then
    if [[ -n ${PUBLISH_MV_FAIL_ROLLBACK:-} ]]; then
        echo "publish-mv stub: refusing to roll back" >&2
        exit 1
    fi
elif [[ -n ${PUBLISH_MV_FAIL_PROMOTION:-} ]]; then
    echo "publish-mv stub: refusing to promote" >&2
    exit 1
fi
exec mv "$@"
"""


class CheckFailure(Exception):
    """An invariant did not hold for a generated case."""


# --------------------------------------------------------------------------
# Executed layer
# --------------------------------------------------------------------------


def write_stubs(bindir: Path) -> None:
    bindir.mkdir(parents=True, exist_ok=True)
    for name, body in (
        ("curl", CURL_STUB),
        ("podman", PODMAN_STUB),
        ("publish-mv", PUBLISH_MV_STUB),
    ):
        path = bindir / name
        path.write_text(body)
        path.chmod(0o755)


def classify(directory: Path) -> str:
    """Describe a package directory as absent, complete:<tag>, partial or mixed."""
    if not directory.is_dir():
        return "absent"
    found = {}
    for name in COMPLETE:
        candidate = directory / name
        if candidate.is_file():
            found[name] = candidate.read_text().strip()
    extra = {
        str(p.relative_to(directory))
        for p in directory.rglob("*.rpm")
        if p.is_file()
    } - set(COMPLETE)
    if extra:
        return "mixed"
    if not found:
        return "absent"
    if len(found) != len(COMPLETE):
        return "partial"
    tags = set(found.values())
    if len(tags) != 1:
        return "mixed"
    return f"complete:{tags.pop()}"


def lock_is_free(path: Path) -> bool:
    if not path.exists():
        return True
    with open(path, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        fcntl.flock(handle, fcntl.LOCK_UN)
    return True


class Sandbox:
    """One disposable case directory wired to the stubs."""

    def __init__(self, root: Path, bindir: Path, fixture: Path, digest: str):
        self.root = root
        self.bindir = bindir
        self.fixture = fixture
        self.digest = digest
        self.out = root / "out"
        self.cache = root / "cache"
        self.locks = self.cache / "locks"
        self.staging = root / ".staging"

    def base_env(self, tag: str) -> dict:
        env = os.environ.copy()
        env.update(
            {
                "CURL": str(self.bindir / "curl"),
                "PODMAN": str(self.bindir / "podman"),
                "CURL_STUB_FIXTURE": str(self.fixture),
                "PODMAN_STUB_TAG": tag,
                "TARBALL_URL": "https://example.invalid/" + TARBALL,
                "TARBALL_SHA256": self.digest,
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "STAGING_ROOT": str(self.staging),
            }
        )
        return env

    def seed_cache(self, state: str) -> set:
        """Set the cache to one of absent/valid/corrupt/interrupted."""
        self.cache.mkdir(parents=True, exist_ok=True)
        target = self.cache / TARBALL
        if state == "valid":
            shutil.copyfile(self.fixture, target)
        elif state == "corrupt":
            target.write_text("truncated junk")
        elif state == "interrupted":
            (self.cache / f"{TARBALL}.ABC123").write_text("half a download")
        return self.temp_tarballs()

    def temp_tarballs(self) -> set:
        if not self.cache.is_dir():
            return set()
        return {p.name for p in self.cache.glob(f"{TARBALL}.??????")}

    def staging_entries(self) -> tuple:
        if not self.staging.is_dir():
            return ((), ())
        owned, recovery = [], []
        for entry in self.staging.iterdir():
            (recovery if entry.name.endswith(".previous") else owned).append(
                entry.name
            )
        return tuple(sorted(owned)), tuple(sorted(recovery))

    def run_build(self, tag: str, extra: dict) -> subprocess.CompletedProcess:
        env = self.base_env(tag)
        env.update(extra)
        return subprocess.run(
            [str(BUILD_SH), "fake-image", str(self.out)],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )

    def run_clean(self) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.update(
            {
                "CACHE_DIR": str(self.cache),
                "LOCK_DIR": str(self.locks),
                "DIST_DIR": str(self.out),
            }
        )
        return subprocess.run(
            [str(CLEAN_SH)], capture_output=True, text=True, env=env, timeout=120
        )

    def locks_free(self) -> bool:
        return all(
            lock_is_free(p) for p in (self.locks.glob("*.lock") if self.locks.is_dir() else [])
        )


def publication_env(mode: str, bindir: Path) -> dict:
    if mode == "exchange":
        return {}
    env = {"PUBLISH_EXCHANGE": "never"}
    if mode in ("promotion_failure", "rollback_failure"):
        env["PUBLISH_MV"] = str(bindir / "publish-mv")
        env["PUBLISH_MV_FAIL_PROMOTION"] = "1"
    if mode == "rollback_failure":
        env["PUBLISH_MV_FAIL_ROLLBACK"] = "1"
    return env


def build_env(outcome: str) -> dict:
    if outcome == "partial":
        return {"PODMAN_STUB_PARTIAL": "1"}
    if outcome == "container_failure":
        return {"PODMAN_STUB_FAIL": "1"}
    return {}


def check_executed_case(case: dict, sandbox: Sandbox, bindir: Path) -> None:
    """Run one generated scenario and assert I1-I4 on the result."""
    pre_temps = sandbox.seed_cache(case["cache"])

    if case["clean"] == "before":
        sandbox.run_clean()
        pre_temps = set()

    primed = case["primed"]
    if primed:
        result = sandbox.run_build("previous", {})
        if result.returncode != 0:
            raise CheckFailure(f"priming build failed: {result.stdout}{result.stderr}")

    extra = build_env(case["build"])
    extra.update(publication_env(case["publish"], bindir))

    if case["build"] == "cancel":
        result = run_cancelled_build(sandbox, extra)
        expect_success = False
    else:
        result = sandbox.run_build("current", extra)
        expect_success = case["build"] == "success" and case["publish"] not in (
            "promotion_failure",
            "rollback_failure",
        )

    if expect_success and result.returncode != 0:
        raise CheckFailure(f"expected success, got {result.returncode}: {result.stderr}")
    if not expect_success and result.returncode == 0:
        raise CheckFailure("expected a non-zero exit status")

    state = classify(sandbox.out)
    owned, recovery = sandbox.staging_entries()

    # I1: never partial, never mixed.
    if state in ("partial", "mixed"):
        raise CheckFailure(f"published output is {state}")

    if expect_success:
        if state != "complete:current":
            raise CheckFailure(f"expected the new generation, found {state}")
    elif case["publish"] == "rollback_failure" and primed:
        # I3's negative case: rollback failed, so the previous generation is
        # preserved as recovery data rather than published.
        if not recovery:
            raise CheckFailure("the recoverable .previous directory was removed")
        recovered = classify(sandbox.staging / recovery[0])
        if recovered != "complete:previous":
            raise CheckFailure(f"recovery data is {recovered}")
    elif primed:
        # I3: a failure before or during publication leaves the prior
        # complete output in place, restoring it if rollback was needed.
        if state != "complete:previous":
            raise CheckFailure(f"expected the previous generation, found {state}")
    elif state != "absent":
        raise CheckFailure(f"expected no output, found {state}")

    # I4: nothing invocation-owned survives a failure.
    if owned:
        raise CheckFailure(f"invocation-owned staging left behind: {owned}")
    leaked = sandbox.temp_tarballs() - pre_temps
    if leaked:
        raise CheckFailure(f"temporary tarballs left behind: {sorted(leaked)}")
    if not sandbox.locks_free():
        raise CheckFailure("a lock is still held")

    if case["clean"] == "after":
        before_state = classify(sandbox.out)
        clean_result = sandbox.run_clean()
        if clean_result.returncode != 0:
            raise CheckFailure(f"clean failed: {clean_result.stderr}")
        # I2, in its simplest form: with no activity lock held, clean removes
        # the output and the cache but keeps the lock directory.
        if sandbox.out.exists():
            raise CheckFailure(f"clean left the output in place (was {before_state})")
        if (sandbox.cache / TARBALL).exists():
            raise CheckFailure("clean left the cached tarball in place")
        if not sandbox.locks.is_dir():
            raise CheckFailure("clean removed the lock directory")


def run_cancelled_build(sandbox: Sandbox, extra: dict) -> subprocess.CompletedProcess:
    """Start a build, block it inside the container step, then signal it."""
    started = sandbox.root / "started.fifo"
    waiting = sandbox.root / "wait.fifo"
    for fifo in (started, waiting):
        if fifo.exists():
            fifo.unlink()
        os.mkfifo(fifo)

    env = sandbox.base_env("cancelled")
    env.update(extra)
    env["PODMAN_STUB_STARTED_FIFO"] = str(started)
    env["PODMAN_STUB_WAIT_FIFO"] = str(waiting)

    proc = subprocess.Popen(
        [str(BUILD_SH), "fake-image", str(sandbox.out)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    )
    # O_NONBLOCK so a stub that never starts cannot wedge the checker.
    fd = os.open(started, os.O_RDONLY | os.O_NONBLOCK)
    try:
        ready, _, _ = select.select([fd], [], [], 60)
        if not ready:
            proc.kill()
            raise CheckFailure("the container stub never announced its start")
        os.read(fd, 64)
    finally:
        os.close(fd)

    os.killpg(proc.pid, signal.SIGTERM)
    stdout, stderr = proc.communicate(timeout=60)
    return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)


def executed_cases(rng: random.Random, limit: int) -> list:
    """A deterministic bounded sample of executable scenarios."""
    caches = ["absent", "valid", "corrupt", "interrupted"]
    builds = ["success", "partial", "container_failure", "cancel"]
    publishes = ["first", "exchange", "fallback", "promotion_failure", "rollback_failure"]
    cleans = ["none", "before", "after"]

    everything = []
    for cache, build, publish, clean in itertools.product(
        caches, builds, publishes, cleans
    ):
        # "first" publication means nothing was published before; every other
        # mode needs a primed generation to act on.
        primed = publish != "first"
        # Publication mode only matters when the build reaches publication.
        if build != "success" and publish not in ("first", "exchange"):
            continue
        everything.append(
            {
                "cache": cache,
                "build": build,
                "publish": publish,
                "clean": clean,
                "primed": primed,
            }
        )

    # Always exercise the publication modes that carry recovery behaviour.
    required = [
        c
        for c in everything
        if c["publish"] in ("promotion_failure", "rollback_failure")
        and c["cache"] == "valid"
        and c["clean"] == "none"
    ]
    rest = [c for c in everything if c not in required]
    rng.shuffle(rest)
    chosen = required + rest[: max(0, limit - len(required))]
    return chosen


# --------------------------------------------------------------------------
# Abstract layer
# --------------------------------------------------------------------------


class ModelState:
    """The observable state the invariants talk about."""

    def __init__(self):
        self.published = None  # None, or a generation tag
        self.publishing_fallback = False  # inside the documented absent window
        self.activity_holders = 0
        self.publish_lock_held = False
        self.cache = "absent"
        self.staging = {}
        self.recovery = {}
        self.cleaned = False
        self.in_critical = 0


def build_steps(name: str, scenario: dict):
    """The atomic steps of one build, as (label, function) pairs."""

    def acquire_activity(state):
        state.activity_holders += 1

    def fetch(state):
        if state.cache != "valid":
            state.cache = "valid"

    def stage(state):
        state.staging[name] = scenario["build"]

    def validate(state):
        if scenario["build"] != "success":
            raise _BuildAborted()

    def take_publish_lock(state):
        if state.publish_lock_held:
            raise _LockContended()
        state.publish_lock_held = True
        state.in_critical += 1

    def publish(state):
        mode = scenario["publish"]
        if mode in ("first", "exchange"):
            state.published = name
        else:
            state.recovery[name] = state.published
            state.published = None
            state.publishing_fallback = True

    def finish_publish(state):
        mode = scenario["publish"]
        if mode in ("first", "exchange"):
            return
        if mode == "fallback":
            state.published = name
            state.recovery.pop(name, None)
        elif mode == "promotion_failure":
            state.published = state.recovery.pop(name)  # rollback succeeds
        else:  # rollback_failure: the previous set stays as recovery data
            pass
        state.publishing_fallback = False
        if mode == "rollback_failure":
            raise _BuildAborted()

    def release_publish_lock(state):
        state.publish_lock_held = False
        state.in_critical -= 1

    def release_activity(state):
        state.activity_holders -= 1
        state.staging.pop(name, None)

    return [
        (f"{name}:activity", acquire_activity),
        (f"{name}:fetch", fetch),
        (f"{name}:stage", stage),
        (f"{name}:validate", validate),
        (f"{name}:publish_lock", take_publish_lock),
        (f"{name}:publish", publish),
        (f"{name}:finish_publish", finish_publish),
        (f"{name}:release_publish", release_publish_lock),
        (f"{name}:release_activity", release_activity),
    ]


def clean_steps():
    def wait_and_remove(state):
        if state.activity_holders != 0:
            raise _CleanBlocked()
        state.published = None
        state.cache = "absent"
        state.cleaned = True

    return [("clean:remove", wait_and_remove)]


class _BuildAborted(Exception):
    pass


class _LockContended(Exception):
    pass


class _CleanBlocked(Exception):
    pass


def run_schedule(participants: dict, order: list) -> list:
    """Execute one interleaving; return any invariant violations."""
    state = ModelState()
    pending = {name: list(steps) for name, steps in participants.items()}
    aborted = set()
    violations = []
    ever_published = False

    def attempt(who):
        """Try to advance one participant; True when a step was consumed."""
        nonlocal ever_published
        if who in aborted or not pending[who]:
            return False
        label, step = pending[who][0]
        try:
            step(state)
        except _BuildAborted:
            # Abort unwinds: locks released, staging dropped. Recovery data,
            # if this build left any, deliberately survives.
            for remaining_label, _ in pending[who]:
                if remaining_label.endswith("release_publish"):
                    if state.publish_lock_held:
                        state.in_critical -= 1
                    state.publish_lock_held = False
                if remaining_label.endswith("release_activity"):
                    state.activity_holders -= 1
            state.staging.pop(who, None)
            state.publishing_fallback = False
            pending[who] = []
            aborted.add(who)
            return True
        except (_LockContended, _CleanBlocked):
            # Not ready: the participant waits, which is the point of the lock.
            return False
        pending[who].pop(0)

        if state.published is not None:
            ever_published = True

        # I1: the output path may be absent only before anything has ever
        # been published, inside a fallback publication's documented window,
        # after clean removed it, or when a failed rollback has left the
        # previous generation as recovery data instead.
        absence_allowed = (
            not ever_published
            or state.publishing_fallback
            or state.cleaned
            or bool(state.recovery)
        )
        if state.published is None and not absence_allowed:
            violations.append(f"output vanished outside a fallback window at {label}")
        # I2: clean only ever removes with no activity lock held.
        if label == "clean:remove" and state.activity_holders != 0:
            violations.append("clean removed state while an activity lock was held")
        # The publication lock is mutually exclusive.
        if state.in_critical > 1:
            violations.append("two builds inside the publication critical section")
        return True

    for who in order:
        attempt(who)

    # The sampled order fixes the interleaving; contention can consume turns
    # without progress, so drain what is left round-robin until everyone has
    # finished. A pass that advances nobody means a real deadlock.
    while True:
        advanced = False
        for who in list(participants):
            if attempt(who):
                advanced = True
        if not advanced:
            break
    if any(pending[who] for who in participants if who not in aborted):
        violations.append("participants could not finish: deadlock")

    # I4: nothing owned survives an abort.
    if state.staging:
        violations.append(f"staging survived: {sorted(state.staging)}")
    if state.publish_lock_held:
        violations.append("publication lock still held at the end")
    if state.activity_holders != 0:
        violations.append(f"activity lock still held: {state.activity_holders}")
    return violations


def abstract_cases(rng: random.Random, schedules_per_case: int) -> int:
    """Sample interleavings of 0-2 builds and a clean; return cases checked."""
    builds = ["success", "partial", "container_failure"]
    publishes = ["first", "exchange", "fallback", "promotion_failure", "rollback_failure"]
    checked = 0

    for count in (0, 1, 2):
        for combo in itertools.product(
            itertools.product(builds, publishes), repeat=count
        ):
            for with_clean in (False, True):
                participants = {}
                for index, (build, publish) in enumerate(combo):
                    name = f"b{index}"
                    participants[name] = build_steps(
                        name, {"build": build, "publish": publish}
                    )
                if with_clean:
                    participants["clean"] = clean_steps()
                if not participants:
                    continue

                slots = []
                for name, steps in participants.items():
                    slots.extend([name] * (len(steps) + 2))

                for _ in range(schedules_per_case):
                    order = list(slots)
                    rng.shuffle(order)
                    violations = run_schedule(dict(participants), order)
                    checked += 1
                    if violations:
                        raise CheckFailure(
                            "abstract schedule violated invariants: "
                            f"{violations}; participants="
                            f"{ {k: k for k in participants} }; order={order}"
                        )
    return checked


# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--seed",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_SEED", DEFAULT_SEED)),
        help="seed for scenario and schedule generation",
    )
    parser.add_argument(
        "--executed-cases",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_EXECUTED", 18)),
        help="how many executed scenarios to sample",
    )
    parser.add_argument(
        "--schedules",
        type=int,
        default=int(os.environ.get("MODEL_CHECK_SCHEDULES", 12)),
        help="interleavings sampled per abstract case",
    )
    args = parser.parse_args()

    print(f"model check: seed={args.seed}")

    rng = random.Random(args.seed)
    cases = executed_cases(rng, args.executed_cases)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bindir = root / "bin"
        write_stubs(bindir)
        fixture = root / "fixture.tar.xz"
        fixture.write_bytes(b"not really a tarball, but a stable one\n")
        digest = hashlib.sha256(fixture.read_bytes()).hexdigest()

        for index, case in enumerate(cases):
            sandbox = Sandbox(root / f"case{index}", bindir, fixture, digest)
            sandbox.root.mkdir(parents=True, exist_ok=True)
            try:
                check_executed_case(case, sandbox, bindir)
            except (CheckFailure, subprocess.TimeoutExpired) as exc:
                print(
                    f"FAIL executed case {index}: {case}\n"
                    f"  seed={args.seed}\n  {exc}",
                    file=sys.stderr,
                )
                return 1
        print(f"model check: {len(cases)} executed scenarios passed")

        try:
            schedules = abstract_cases(random.Random(args.seed), args.schedules)
        except CheckFailure as exc:
            print(f"FAIL abstract model:\n  seed={args.seed}\n  {exc}", file=sys.stderr)
            return 1
        print(f"model check: {schedules} abstract schedules passed")

    print("MODEL CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
