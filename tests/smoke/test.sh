#!/bin/bash
# Smoke test: the built packages are installed, intact, and loadable.
set -euxo pipefail

# Installed at the expected version, with epoch preserved for upgrade paths
rpm -q bash-completion
rpm -q bash-completion-devel
evr=$(rpm -q --qf '%{EPOCH}:%{VERSION}' bash-completion)
test "$evr" = "1:2.18.0"

# File integrity as shipped
rpm -V bash-completion
rpm -V bash-completion-devel

# Key payload present
test -f /usr/share/bash-completion/bash_completion
test -f /etc/profile.d/bash_completion.sh
test -d /usr/share/bash-completion/completions-core
test -d /usr/share/bash-completion/completions-fallback

# Completions removed to avoid conflicts with other packages stay removed
for f in cowsay cowthink makepkg prelink javaws; do
    test ! -e "/usr/share/bash-completion/completions-core/${f}.bash"
done
test ! -e /usr/share/bash-completion/completions-fallback/interdiff.bash

# The profile.d hook is a no-op in non-interactive shells...
bash --norc -c 'source /etc/profile.d/bash_completion.sh; [ -z "${BASH_COMPLETION_VERSINFO-}" ]'
# ...and loads bash-completion in interactive login shells
ver=$(bash -lic 'echo "${BASH_COMPLETION_VERSINFO[*]}"' 2>/dev/null | tail -n1)
echo "$ver" | grep -qE '^2 18'

# The main file sources cleanly on its own
bash --norc -c 'source /usr/share/bash-completion/bash_completion'

# devel subpackage is usable
pkg-config --exists bash-completion
test "$(pkg-config --modversion bash-completion)" = "2.18.0"
pkg-config --variable=completionsdir bash-completion | grep -q '^/usr/share/bash-completion/completions$'
test -f /usr/share/cmake/bash-completion/bash-completion-config.cmake

echo "SMOKE OK"
