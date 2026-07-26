# Digest-pinned for reproducibility; this is fedora:43 as of 2026-07-26.
FEDORA_IMAGE := registry.fedoraproject.org/fedora@sha256:af06c24b2e90bef115bba80e428ac21466db8869ad544f3424b969513b67eeae
# quay.io rather than docker.io: Docker Hub rate-limits anonymous pulls,
# which bites on shared CI runner IPs. Digest-pinned for reproducibility;
# this is rockylinux:10 as of 2026-07-25.
ROCKY_IMAGE  := quay.io/rockylinux/rockylinux@sha256:827d37bc128288ccf160ee318bb3cb92d591164cb217e92f8bc61e3982ae1834

# netavark's nftables firewall rules fail on WSL2 kernels; they are not
# needed for these rootless test containers, so tell netavark to skip them
# there. Elsewhere (including CI runners, whose older netavark rejects the
# "none" backend) leave the default firewall driver alone.
IS_WSL := $(shell grep -qi microsoft /proc/version 2>/dev/null && echo 1)
ifeq ($(IS_WSL),1)
TMT := NETAVARK_FW=none tmt
else
TMT := tmt
endif

.PHONY: all rpms rpm-fedora-43 rpm-rocky-10 test test-fedora-43 test-rocky-10 lint clean

# The rpm targets share the .build tarball cache and the test targets share
# podman resources; parallel make would race on both.
.NOTPARALLEL:

all: test

rpms: rpm-fedora-43 rpm-rocky-10

rpm-fedora-43:
	scripts/build-rpm.sh $(FEDORA_IMAGE) dist/fedora-43

rpm-rocky-10:
	scripts/build-rpm.sh $(ROCKY_IMAGE) dist/rocky-10

# Test plans run sequentially, one podman container per plan.
test: test-fedora-43 test-rocky-10

test-fedora-43: rpm-fedora-43
	$(TMT) run -v --scratch --id fedora-43 plan --name /plans/fedora-43

test-rocky-10: rpm-rocky-10
	$(TMT) run -v --scratch --id rocky-10 plan --name /plans/rocky-10

lint:
	tmt lint

clean:
	rm -rf dist .build
