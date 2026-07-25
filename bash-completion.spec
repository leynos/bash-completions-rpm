# Rebuild of upstream bash-completion 2.18.0 for Fedora 43 and Rocky Linux 10.
# Based on the Fedora rawhide spec, with distribution patches dropped (none
# are needed against 2.18.0) and the dejagnu test machinery removed.

# The *.py files we ship are not python scripts, rhbz#813651
%global _python_bytecompile_errors_terminate_build 0
%global upstream_version 2.18.0

Name:           bash-completion
Version:        2.18.0
Release:        1%{?dist}
Epoch:          1
Summary:        Programmable completion for Bash

License:        GPL-2.0-or-later
URL:            https://github.com/scop/bash-completion
Source0:        https://github.com/scop/bash-completion/releases/download/%{upstream_version}/%{name}-%{upstream_version}.tar.xz

BuildArch:      noarch
BuildRequires:  make
Requires:       bash >= 4.1

%description
bash-completion is a collection of shell functions that take advantage
of the programmable completion feature of bash.

%package devel
Summary:        Development files for %{name}
Requires:       %{name} = %{epoch}:%{version}-%{release}

%description devel
This package contains development files for %{name}.

%prep
%autosetup -n %{name}-%{upstream_version} -p1

%build
%configure
%make_build

%install
%make_install

# Updated completion shipped in cowsay package:
rm %{buildroot}%{_datadir}/bash-completion/completions-core/{cowsay,cowthink}.bash

# rhbz#1819867 - conflict over the makepkg name with pacman
rm %{buildroot}%{_datadir}/bash-completion/completions-core/makepkg.bash

# rhbz#2088307 - Remove completions for prelink
rm %{buildroot}%{_datadir}/bash-completion/completions-core/prelink.bash

# rhbz#2188865 - Remove bash completions for javaws as it's not shipped
rm %{buildroot}%{_datadir}/bash-completion/completions-core/javaws.bash

# rhbz#2391218 - patchutils package contains its own completion for this
rm %{buildroot}%{_datadir}/bash-completion/completions-fallback/interdiff.bash

%check
# For some tests involving non-ASCII filenames
export LANG=C.UTF-8
make -C completions check

%files
%license COPYING
%doc AUTHORS CHANGELOG.md CONTRIBUTING.md README.md
%doc doc/configuration.md doc/styleguide.md
%config(noreplace) %{_sysconfdir}/profile.d/bash_completion.sh
%{_datadir}/bash-completion/

%files devel
%{_datadir}/cmake/
%{_datadir}/pkgconfig/bash-completion.pc

%changelog
* Sat Jul 25 2026 Payton McIntosh <leynos@troubledskies.net> - 1:2.18.0-1
- Rebuild of upstream 2.18.0 for Fedora 43 and Rocky Linux 10
