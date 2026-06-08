# flux-pam

[![CI](https://github.com/flux-framework/flux-pam/actions/workflows/main.yml/badge.svg)](https://github.com/flux-framework/flux-pam/actions/workflows/main.yml)

PAM module for the [Flux](https://flux-framework.org) resource management
framework. Restricts node access to users with active Flux jobs on the node.
When systemd integration is enabled, manages the user's systemd instance
lifecycle and maintains slice resource constraints as the union of all
resources allocated to that user's active jobs, placing authorized login
sessions within the constrained slice.

## Overview

flux-pam provides two cooperating components:

**`pam_flux.so`** — A PAM module with account and session management
functions. The account module grants or denies login access based on whether
the user has an active Flux job on the node. The session module places
admitted logins into a transient systemd scope under the user's managed
slice, ensuring SSH sessions and other interactive access share the same
resource constraints as the job.

**Prolog and housekeeping scripts** — `flux-pam-prolog` and
`flux-pam-housekeeping` run on each compute node at job start and
completion. The prolog applies resource constraints to the user slice,
creates an active marker file, and best-effort starts `user@UID.service`.
Housekeeping updates constraints as jobs end and clears the marker when
the user's last job completes. The PAM session module checks for the
marker's presence under lock before admitting logins, ensuring
containment is set up. Slice-based containment works even when
`user@UID.service` fails to start (e.g., on nodes with `/proc` mounted
`hidepid=2`).

## Requirements

| Requirement | Notes |
|---|---|
| [Flux](https://github.com/flux-framework/flux-core) ≥ 0.64.0 | System instance required |
| PAM development headers | `pam-devel` (RHEL/Fedora) or `libpam-dev` (Debian/Ubuntu) |
| systemd ≥ 239 | Required for session management and slice features |
| libsystemd development headers | `systemd-devel` or `libsystemd-dev` |
| cgroup v2 (unified hierarchy) | Required for `pam.manage-user-slice`; device and resource constraints do not work on cgroup v1 |

Build tools: `autoconf`, `automake`, `libtool`, `pkg-config`.

## Installation

```sh
./autogen.sh
./configure --prefix=/usr
make
make install
```

The PAM module installs to `$libdir/security` (e.g. `/usr/lib64/security`).
Use `--enable-securedir=DIR` to override.

When systemd integration is enabled, `make install` creates a tmpfiles.d
drop-in at `/usr/lib/tmpfiles.d/flux-pam.conf` that creates `/run/flux-pam`
with correct permissions (mode `0700`, owned by root) at boot. If you
manually create this directory, ensure it has these exact permissions.

### Packages

Debian packages can be built with:

```sh
make deb
```

## Configuration

### Access control only

Add `pam_flux.so` as an `account` provider. Users without an active Flux
job on the node are denied with an informative message.

```
# /etc/pam.d/sshd (or equivalent)
account  required    pam_unix.so
account  sufficient  pam_access.so
account  sufficient  pam_flux.so
account  required    pam_deny.so
```

To also allow users into a running multi-user Flux instance as guests:

```
account  required    pam_unix.so
account  sufficient  pam_flux.so allow-guest-user
```

### Full configuration with session management

Session management places each login inside the user's systemd slice,
enforcing the same resource limits as their job. Logins are admitted only
when an active marker file exists, which the prolog creates after applying
constraints and housekeeping removes at last-job teardown. This ensures
sessions cannot attach before containment is ready or after it has been
torn down. Session management requires `pam.manage-user-slice = true` in
the Flux system configuration and the prolog/housekeeping scripts to be
active (see below).

```
# /etc/pam.d/sshd (or equivalent)
auth     required    pam_unix.so

account  required    pam_unix.so
account  sufficient  pam_access.so
account  sufficient  pam_flux.so allow-guest-user
account  required    pam_deny.so

session  requisite   pam_flux.so
session  required    pam_limits.so
session  required    pam_unix.so
```

> **Note:** Place `pam_flux.so` first in the session stack. With
> `requisite`, a slice setup failure denies the session immediately before
> any other session module runs.

> **Note:** Do not use `pam_systemd.so` alongside `pam_flux.so` session
> management. logind's process migration and service lifecycle management
> conflict with Flux's job-driven slice management. See
> [pam_flux(8)](doc/man8/pam_flux.rst) for details.

### Flux system configuration

Enable slice lifecycle management and, optionally, resource constraints:

```toml
# /etc/flux/system/conf.d/pam.toml

[pam]
manage-user-slice = true      # enable slice lifecycle and marker management

[exec]
service = "sdexec"
sdexec-constrain-resources = true  # apply CPU/memory/device limits to slice
```

For the prolog and housekeeping scripts to run, the Flux job manager must
be configured with the `perilog.so` plugin and `per-rank = true`, and the
IMP must allow the prolog/housekeeping wrappers:

```toml
# /etc/flux/system/conf.d/perilog.toml
[job-manager]
plugins = [ { load = "perilog.so" } ]

[job-manager.prolog]
per-rank = true

[job-manager.housekeeping]
per-rank = true
```

```toml
# /etc/flux/imp/conf.d/pam.toml
[run.prolog]
allowed-users = [ "flux" ]
allowed-environment = [ "FLUX_*" ]
path = "/usr/libexec/flux/cmd/flux-run-prolog"

[run.housekeeping]
allowed-users = [ "flux" ]
allowed-environment = [ "FLUX_*" ]
path = "/usr/libexec/flux/cmd/flux-run-housekeeping"
```

See [flux-config-pam(5)](doc/man5/flux-config-pam.rst) for all available
configuration options including orphan process cleanup.

## Documentation

| Man page | Description |
|---|---|
| [pam_flux(8)](doc/man8/pam_flux.rst) | PAM module options and PAM stack configuration |
| [flux-config-pam(5)](doc/man5/flux-config-pam.rst) | Flux configuration for prolog/housekeeping and session management |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

LGPL-3.0 — see [COPYING](COPYING).

LLNL-CODE-764420
