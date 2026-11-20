===========
pam_flux(8)
===========

SYNOPSIS
========

  :command:`pam_flux.so` [allow-guest-user] [scope-prefix=PREFIX] [lock-dir=DIR] [uri=URI] [debug]

DESCRIPTION
===========

Restricts node access on Flux system instances and, optionally, places
login sessions inside the user's resource-constrained systemd slice.

Account Management
------------------

Only users with an active Flux job on the node are granted access.
Users without one are denied with the message:
::

  Access denied: user [username] has no active jobs on this node

Add the module as an account provider with the ``sufficient`` control field,
so other account modules (e.g. ``pam_access.so``) can also grant access::

  account sufficient pam_flux.so [OPTIONS]

PAM ignores a failed ``sufficient`` module, so end the account stack with
``pam_deny.so``. Otherwise, users without a job are admitted. If
``pam_flux.so`` is the only module that grants access, use ``required``
instead.

Session Management
------------------

When ``pam.manage-user-slice`` is enabled in the Flux configuration (see
:man5:`flux-config-pam`), the session module performs the following for
each admitted session:

- Acquires a per-user lock (``/run/flux-pam/uid.$UID.lock``) to serialize
  with prolog/housekeeping scripts
- Checks the active marker file (``/run/flux-pam/uid.$UID.active``). The
  prolog creates this after applying constraints; housekeeping removes it at
  last-job teardown. Absence of the marker denies the session.
- Creates a transient systemd scope (``<scope-prefix>-<pid>.scope``,
  default ``flux-pam-<pid>.scope``) under ``user-$UID.slice`` to contain
  the session processes.
- Sets ``XDG_RUNTIME_DIR`` and ``DBUS_SESSION_BUS_ADDRESS`` in the
  session environment.

The session module does not read ``exec.sdexec-constrain-resources``; it
places the session in ``user-$UID.slice`` regardless of whether resource
constraints are configured. When ``exec.sdexec-constrain-resources`` is
disabled, the slice carries no resource limits, so the session is contained
in the user's slice but is not restricted to the resources allocated to the
user's jobs. When it is enabled, the prolog applies resource limits to the
slice and the session inherits them. See BEHAVIOR in
:man5:`flux-config-pam`.

The session module only activates for users the ``pam_flux.so`` account
module admitted as the owner of a job on this node. Users admitted by
another account module, and guests admitted under ``allow-guest-user``,
receive ``PAM_IGNORE`` and their sessions run in the default cgroup. A
guest has no job of their own on the node, so there is no slice holding
the resources their session should be confined to.

The session module also skips the Flux instance owner, for whom the
prolog manages no slice. If ``pam_flux.so`` was built without libsystemd,
it denies all job owner sessions while ``pam.manage-user-slice`` is
enabled.

The session module depends on the account module to identify job owners,
so ``pam_flux.so`` must appear in both the account and session stacks.
Add it as the first session provider with the ``requisite`` control
field::

  session requisite pam_flux.so [OPTIONS]

If session setup fails, ``requisite`` ends the stack immediately, so no
other session module runs for a login that will be denied. ``required``
also denies the login, but only after all remaining session modules
have run. ``optional`` or ``sufficient`` would admit the user without
containment.

See EXAMPLES for a complete stack configuration.

Session management requires the flux-pam prolog and housekeeping scripts (see
:man5:`flux-config-pam`).

OPTIONS
=======

Account Management Options
--------------------------

allow-guest-user
  Also allows access if all of the following are true:

   - the system instance owner (as encoded in the ``security.owner``
     attribute) has an active job on the current node
   - the current node is rank 0 of that job
   - the job is an instance of Flux
   - ``access.allow-guest-user`` is set to ``true`` in the instance
     configuration

  Guests admitted this way are not placed in a slice by the session
  module. See Session Management.

Session Management Options
--------------------------

scope-prefix=PREFIX
  Prefix for the transient systemd scope created for the login session.
  Scopes are named ``PREFIX-PID.scope``. (Default: ``flux-pam``).

lock-dir=DIR
  Directory for per-user lock files and active markers, shared with the
  prolog and housekeeping scripts. Used by the session module and by the
  account module for ``systemd-user``. The directory must exist, be owned
  by root, and have permissions ``0700`` (owner read/write/execute only).
  If the directory has group or other write permissions, lock acquisition
  will fail with an error. The directory is created with correct permissions
  by the flux-pam tmpfiles.d drop-in at boot.
  (Default: ``/run/flux-pam``).

Common Options
--------------

uri=URI
  Connect to the Flux instance at ``URI``, which must be a ``local://``
  URI with an absolute path, no ``..`` component, and no whitespace.
  (Default: the system instance of the installed flux-core).

  The module should always use the system install and system instance
  of Flux, so while it calls Flux it removes all ``FLUX_*`` variables
  from the environment, and restores them afterward. ``FLUX_URI`` is
  therefore never used, and another instance can only be selected with
  ``uri``. This should rarely be needed except for testing.

debug
  Enable additional logging. For account management, logs successful grants
  at ``LOG_INFO`` level; failures are always logged regardless. For session
  management, logs scope creation details and marker checks.

EXAMPLES
========

Account Management Only
-----------------------

Grant access to Flux job users and guests of multi-user instances::

    account required    pam_unix.so
    account sufficient  pam_flux.so allow-guest-user
    account required    pam_deny.so

Combined Account and Session Management
---------------------------------------

Flux job users get access control and session containment; users admitted
by other account modules (e.g. administrators) get ``PAM_IGNORE`` from the
session module and are handled by subsequent modules::

    auth       required    pam_unix.so

    account    required    pam_unix.so
    account    sufficient  pam_access.so
    account    sufficient  pam_flux.so allow-guest-user
    account    required    pam_deny.so

    session    requisite   pam_flux.so
    session    required    pam_limits.so
    session    required    pam_unix.so

.. note::
   Place ``pam_flux.so`` first in the session stack with ``requisite``,
   so a session setup failure denies the login before any other session
   module runs. See Session Management.

   Session management is only active when ``pam.manage-user-slice = true``
   is set in the Flux configuration. See :man5:`flux-config-pam`.

NOTES
=====

systemd-user Service
--------------------

Each user can have a systemd user manager (``systemd --user``), which
provides ``systemctl --user``, user timers, and the user D-Bus. It runs
as the system service ``user@$UID.service``. With ``pam.manage-user-slice``
enabled, the flux-pam prolog starts it when a job starts on the node, and
housekeeping stops it after the user's last job (see :man5:`flux-config-pam`).

To start the user manager, systemd runs the PAM configuration for the
``systemd-user`` service (see :linux:man5:`pam.d`). On many systems this
configuration includes a shared one, such as ``password-auth`` or
``common-account``, and so may include ``pam_flux.so``.

Account
  The account stack must admit job users, or the user manager fails to
  start. For ``systemd-user``, the ``pam_flux.so`` account module admits
  users with an active job on the node, and never denies anyone. While
  the prolog starts the user manager, it admits on the prolog's active
  marker, since Flux may not yet report the new job. For all other
  users, including when Flux is unreachable, it returns ``PAM_IGNORE``,
  and the rest of the stack decides as if ``pam_flux.so`` were not
  present.

  If the stack ends in ``pam_deny.so``, it must also admit service
  accounts that need a user manager, such as the Flux instance owner.

Session
  The ``pam_flux.so`` session module returns ``PAM_IGNORE`` for
  ``systemd-user`` without creating a scope, so the rest of the session
  runs normally. For a login, it moves the login process into a new
  scope, ``flux-pam-<pid>.scope`` (see Session Management). Doing that
  for the user manager would move it out of ``user@$UID.service``, where
  systemd expects it.

/proc with hidepid
------------------

flux-pam tolerates ``hidepid=2`` on ``/proc``, which breaks
``user@$UID.service`` startup (see PROCFS WITH HIDEPID in
:man5:`flux-config-pam`). Logins work even when the user manager
fails. Tradeoff: no ``systemctl --user`` units, user D-Bus, or user
timers during jobs.

cgroup v2 Requirement
---------------------

Session management (``pam.manage-user-slice``) requires the cgroup v2 unified
hierarchy and systemd ≥ 239. Resource constraints
(``exec.sdexec-constrain-resources``) require systemd ≥ 244, which added
``AllowedCPUs`` and ``AllowedMemoryNodes``. Resource properties such as
``AllowedCPUs``, ``DevicePolicy``, and ``DeviceAllow`` are applied to user
slice units via ``systemctl set-property --runtime``, which systemd only
enforces on the unified hierarchy. cgroup v1 systems are not supported.

Logind Incompatibility
-----------------------

``pam_flux.so`` session management bypasses logind and is therefore
**incompatible** with ``pam_systemd.so``. Do not include ``pam_systemd.so``
in the session stack alongside ``pam_flux.so`` when ``pam.manage-user-slice``
is enabled.

This is not a limitation of ``pam_systemd.so`` specifically but of logind
itself. Any logind-based approach to session or service lifecycle management
— including ``loginctl enable-linger`` — suffers from the same two
fundamental incompatibilities with Flux:

First, when logind creates a user's first login session it migrates all
existing processes owned by that user from their current cgroups into
``user-$UID.slice``. This pulls active Flux job processes out of the
job-specific cgroup hierarchies where Flux placed them, breaking Flux's
ability to track and constrain those processes by job.

Second, logind drives the ``user@$UID.service`` lifecycle from login session
count, starting the service when the first session opens and stopping it
when the last session closes. Flux drives the same service from job count
via the prolog and housekeeping scripts. A user who logs out while a job
is still running causes logind to stop the service prematurely, releasing
job processes from cgroup containment before the job completes.

``pam_flux.so`` avoids both problems by managing scope units directly via
the systemd D-Bus API, bypassing logind entirely. As a result:

- Sessions are not registered with logind and will not appear in
  ``loginctl list-sessions`` output.
- ``XDG_SESSION_ID`` is not set in the login shell environment.
- Scope units are named ``flux-pam-<pid>.scope`` (or with a custom prefix)
  rather than the logind-assigned ``session-N.scope``.

TROUBLESHOOTING
===============

Logs
----

``pam_flux.so`` logs to syslog with :linux:man3:`pam_syslog`, tagged
``pam_flux(SERVICE:TYPE)``, e.g. ``pam_flux(sshd:session)``. On most
systems these messages appear in the journal and in ``/var/log/secure``
or ``/var/log/auth.log``::

  journalctl | grep pam_flux

Errors and denials are always logged. Add ``debug`` to both the account
and session lines to also log grants, skipped sessions, marker checks,
and scope creation.

The prolog and housekeeping scripts write errors to stderr. The Flux
job manager logs this output on rank 0, so view it on the management
node with :core:man1:`flux-dmesg`, not on the compute node. Set
``pam.debug = true`` to log each action (see :man5:`flux-config-pam`).

Verifying Operation
-------------------

To check a deployment with ``pam.manage-user-slice`` enabled:

1. On the compute node, confirm the configuration with
   ``flux config get pam``.
2. Submit a job to the node as a test user. Confirm the active marker
   ``/run/flux-pam/uid.UID.active`` exists. If resource constraints are
   enabled, confirm the slice properties with
   ``systemctl show user-UID.slice -p AllowedCPUs -p DeviceAllow``.
3. Log in to the node as the test user. Confirm that
   ``cat /proc/self/cgroup`` shows ``user-UID.slice/flux-pam-PID.scope``.
4. After the job completes, confirm the marker is removed and a new
   login is denied.

Common Problems
---------------

Login denied with "no active jobs" while the user has a job
  If the account module denied the login, check that the job is running
  on this node. If the session module denied it, the active marker is
  missing: the prolog did not run or failed. Check the perilog and IMP
  configuration in :man5:`flux-config-pam` and look for errors with
  :core:man1:`flux-dmesg`.

"lock dir ... must not be group/other writable"
  Fix the permissions on the lock directory (see ``lock-dir``).

"StartTransientUnit(...) failed"
  The session module could not create the scope through systemd. Check
  the systemd journal for the reason.

Login admitted but not contained
  The user was admitted by another account module, or is a guest or the
  instance owner (see Session Management). Also check that
  ``pam_systemd.so`` is not in the session stack.

``user@UID.service`` fails to start
  Jobs and logins still work, but ``systemctl --user`` does not. Check
  ``journalctl -u user@UID.service``. A PAM failure there, such as
  "Failed to set up PAM session", means the ``systemd-user`` stack denies
  the user (see systemd-user Service). ``pam_flux.so`` never denies for
  ``systemd-user``, so for a job user, check that ``pam_flux.so`` is in the
  account stack before any module that denies. For the Flux instance owner
  or another service account, check that the stack admits the account
  before it reaches ``pam_deny.so``. On nodes with ``hidepid=2``, see
  /proc with hidepid.

RESOURCES
=========

Flux Administrator's Guide: https://flux-framework.readthedocs.io/projects/flux-core/en/latest/guide/admin.html

SEE ALSO
========

:man5:`flux-config-pam`,
:core:man5:`flux-config-access`,
:linux:man5:`pam.d`,
:linux:man5:`pam.conf`,
:linux:man7:`pam`
