#!/usr/bin/env bash
# Remove build output and the cached upstream tarball.
#
# Usage: scripts/clean.sh
#
# Clean is serialized against every build: scripts/build-rpm.sh holds
# .build/locks/activity.lock shared for its whole run, and this script takes
# the same lock exclusively, so it waits for in-flight builds to finish and
# no build can start while it is removing anything. That is what keeps it
# from deleting a directory a build is currently publishing into.
#
# .build/locks/ itself is deliberately preserved. Removing a lock file while
# holding a lock on it would let a waiting process take a lock on the unlinked
# inode and proceed as though it had exclusive access.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

: "${FLOCK:=flock}"
: "${CACHE_DIR:=${repo_root}/.build}"
: "${LOCK_DIR:=${CACHE_DIR}/locks}"
: "${DIST_DIR:=${repo_root}/dist}"
# Test seam: a command run immediately before blocking on the lock, which
# lets the unit tests observe the waiting state without a timing sleep.
: "${CLEAN_PRELOCK_HOOK:=}"

[[ -n ${CACHE_DIR} && -n ${DIST_DIR} ]] ||
    { echo "$0: CACHE_DIR and DIST_DIR must not be empty" >&2; exit 2; }

mkdir -p "${LOCK_DIR}"

if [[ -n ${CLEAN_PRELOCK_HOOK} ]]; then
    "${CLEAN_PRELOCK_HOOK}"
fi

exec {activity_fd}>"${LOCK_DIR}/activity.lock"
"${FLOCK}" -x "${activity_fd}"

rm -rf "${DIST_DIR}"

# Everything in the cache except the lock directory.
if [[ -d ${CACHE_DIR} ]]; then
    find "${CACHE_DIR}" -mindepth 1 -maxdepth 1 \
        ! -name "$(basename "${LOCK_DIR}")" -exec rm -rf {} +
fi

exec {activity_fd}>&-

echo "Removed ${DIST_DIR} and the cached tarball; kept ${LOCK_DIR}"
