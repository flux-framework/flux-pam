===========
pam_flux(8)
===========

SYNOPSIS
========

  :command:`pam_flux.so` [allow-guest-user] [scope-prefix=PREFIX] [lock-dir=DIR] [debug]

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

Add the module as an account provider with the ``sufficient`` control field::

  account sufficient pam_flux.so [OPTIONS]

Session Management
------------------

When ``pam.manage-user-slice`` is enabled in the Flux configuration (see
:man5:`flux-config-pam`), the session module performs the following for
each admitted session:

- Acquires a per-user lock (``<lock-dir>/uid.$UID.lock``, default
  ``/run/flux-pam/uid.$UID.lock``) to serialize service verification and
  scope creation with the prolog and housekeeping scripts, preventing a
  race between session setup and concurrent job teardown.
- Verifies that ``user@$UID.service`` is active. An inactive service
  indicates the prolog did not complete slice setup successfully; the
  session is denied to prevent uncontained access pending administrator
  review.
- Creates a transient systemd scope (``<scope-prefix>-<pid>.scope``,
  default ``flux-pam-<pid>.scope``) under ``user-$UID.slice`` to contain
  the session processes.
- Sets ``XDG_RUNTIME_DIR`` and ``DBUS_SESSION_BUS_ADDRESS`` in the
  session environment.

The session module only activates for users granted access by the
``pam_flux.so`` account module; users admitted by other account modules
receive ``PAM_IGNORE`` and their sessions run in the default cgroup.
``pam_flux.so`` must therefore appear in both the account and session
stacks. Add it as a session provider with the ``requisite`` control field::

  session requisite pam_flux.so [OPTIONS]

See EXAMPLES for a complete stack configuration.

Session management depends on the flux-pam prolog and housekeeping scripts
to manage the ``user@$UID.service`` lifecycle and user slice properties.
See :man5:`flux-config-pam`.

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

Session Management Options
--------------------------

scope-prefix=PREFIX
  Prefix for the transient systemd scope created for the login session.
  Scopes are named ``PREFIX-PID.scope``. (Default: ``flux-pam``).

lock-dir=DIR
  Directory for per-user lock files used to serialize session setup with
  the prolog and housekeeping scripts. The directory must exist, be owned
  by root, and have permissions ``0700`` (owner read/write/execute only).
  If the directory has group or other write permissions, lock acquisition
  will fail with an error. The directory is created with correct permissions
  by the flux-pam tmpfiles.d drop-in at boot.
  (Default: ``/run/flux-pam``).

Common Options
--------------

debug
  Enable additional logging. For account management, logs successful grants
  at ``LOG_INFO`` level; failures are always logged regardless. For session
  management, logs scope creation details and service state checks.

EXAMPLES
========

Account Management Only
-----------------------

Grant access to Flux job users and guests of multi-user instances::

    account required    pam_unix.so
    account sufficient  pam_flux.so allow-guest-user

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
   Place ``pam_flux.so`` first in the session stack. With ``requisite``,
   a slice setup failure denies the session immediately before any other
   session module runs. Use ``requisite`` rather than ``required`` or
   ``optional`` to prevent the user from reaching the node without
   containment if setup fails.

   Session management is only active when ``pam.manage-user-slice = true``
   is set in the Flux configuration. See :man5:`flux-config-pam`.

NOTES
=====

cgroup v2 Requirement
---------------------

Session management (``pam.manage-user-slice``) requires the cgroup v2 unified
hierarchy (systemd ≥ 239). Resource properties such as ``AllowedCPUs``,
``DevicePolicy``, and ``DeviceAllow`` are applied to user slice units via
``systemctl set-property --runtime``, which systemd only enforces on the
unified hierarchy. cgroup v1 systems are not supported.

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
