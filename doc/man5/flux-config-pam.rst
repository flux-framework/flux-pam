====================
flux-config-pam(5)
====================


DESCRIPTION
===========

The ``pam`` table configures flux-pam features that manage systemd user
slices for Flux job users. This includes:

- The flux-pam prolog and housekeeping scripts, which run during job prolog
  and housekeeping phases to manage slice constraints and a per-user active
  marker, and best-effort attempt to start ``user@$UID.service``.
- The ``pam_flux.so`` PAM session module, which attaches login sessions
  authenticated via the account module to the user's managed slice when
  ``manage-user-slice`` is enabled. See :man8:`pam_flux`.

PREREQUISITES
=============

``pam.manage-user-slice`` requires systemd ≥ 239 and the cgroup v2 unified
hierarchy. Resource constraints (``AllowedCPUs``, ``AllowedMemoryNodes``,
``DevicePolicy``, ``DeviceAllow``) are applied to user slice units via
``systemctl set-property --runtime``, which is only enforced by systemd on
the unified hierarchy. cgroup v1 systems are not supported.

When ``pam.manage-user-slice`` is enabled, **systemd linger must not be
enabled for job users on compute nodes.** Linger (``loginctl enable-linger``)
keeps ``user@UID.service`` running independently of jobs, bypassing Flux
control. The prolog fails immediately if linger is detected.

The prolog applies resource constraints to the user slice, creates an
active marker file, and best-effort starts ``user@$UID.service`` (for
background, see PROCFS WITH HIDEPID below). The PAM session module checks
the marker under lock before admitting logins.

The flux-pam package installs ``flux-pam-prolog`` and
``flux-pam-housekeeping`` into ``$libexecdir/flux/prolog.d/`` and
``$libexecdir/flux/housekeeping.d/``, where they are run by
``flux-run-prolog`` and ``flux-run-housekeeping`` respectively.

For these scripts to execute on compute nodes, the Flux system instance
must load the ``perilog.so`` job-manager plugin with ``per-rank = true``
for prolog and housekeeping. With ``per-rank = true``, the default
command is ``flux-imp run prolog`` (or ``housekeeping``), which invokes
``flux-run-prolog`` (or ``flux-run-housekeeping``) as root, executing
all scripts in the drop-in directory.

Flux system instance (``/etc/flux/system/conf.d/``)::

   [job-manager]
   plugins = [
     { load = "perilog.so" }
   ]

   [job-manager.prolog]
   per-rank = true

   [job-manager.housekeeping]
   per-rank = true

IMP (``/etc/flux/imp/conf.d/``)::

   [run.prolog]
   allowed-users = [ "flux" ]
   allowed-environment = [ "FLUX_*" ]
   path = "/usr/libexec/flux/cmd/flux-run-prolog"

   [run.housekeeping]
   allowed-users = [ "flux" ]
   allowed-environment = [ "FLUX_*" ]
   path = "/usr/libexec/flux/cmd/flux-run-housekeeping"

See :core:man5:`flux-config-job-manager` and the Flux Administrator's
Guide for further details.


KEYS
====

All keys are optional and default to ``false`` unless otherwise noted.

manage-user-slice
   Boolean value that enables systemd user slice management via prolog and
   housekeeping scripts. When enabled, the prolog applies slice constraints,
   publishes the active marker, and best-effort starts ``user@$UID.service``;
   housekeeping reverts and clears the marker when the last job completes.
   This is the master switch for all user slice management features,
   including session attachment in ``pam_flux.so`` (see :man8:`pam_flux`).
   (Default: ``false``).

   When this feature is disabled, prolog and housekeeping scripts exit
   early without managing user slices or markers. This includes the
   instance owner (who always skips management).

kill-user-slice
   Boolean value that controls whether housekeeping actively terminates
   processes remaining in the user slice during last-job slice teardown.
   (Default: ``false``).

   When set to ``true``, housekeeping implements aggressive cleanup:

   - Checks for orphan processes (processes in ``user-UID.slice`` but not
     under ``user@UID.service``, such as leftover SSH sessions or other
     systemd scopes)
   - If orphans exist, sends ``SIGTERM`` to all processes in the slice
   - Waits for ``kill-slice-grace-time`` for processes to exit
   - If processes remain, sends ``SIGKILL`` to all processes in the slice
   - Waits for ``kill-slice-grace-time`` again
   - If processes still remain, raises an error and drains the node

   When set to ``false`` (the default), housekeeping best-effort stops
   ``user@UID.service`` without attempting to kill processes. Cleanup is
   delegated to other mechanisms such as site-specific tools.

   .. warning::
      All processes in the user's slice — including interactive login
      sessions — are terminated when the last job completes.

kill-slice-grace-time
   Duration in Flux Standard Duration (FSD) format specifying how long to
   wait for processes to exit after each kill signal. Only applies when
   ``kill-user-slice = true``. (Default: ``"30s"``).

   The grace time is applied twice: once after ``SIGTERM``, once after
   ``SIGKILL``. Maximum total cleanup time is therefore
   ``2 * kill-slice-grace-time``. If processes remain after both waits,
   housekeeping drains the node.

   See :doc:`rfc:spec_23` for the FSD format specification.

debug
   Boolean value that enables verbose debug logging for the prolog and
   housekeeping scripts. When ``true``, each script logs its actions to
   stderr, which is captured in the Flux job-manager log. Equivalent to
   setting the ``FLUX_PAM_SCRIPTS_DEBUG`` environment variable.
   (Default: ``false``).


RESOURCE CONSTRAINTS
====================

The ``pam`` table works in conjunction with the ``exec`` configuration
for resource management:

exec.sdexec-constrain-resources
   When enabled (along with ``pam.manage-user-slice``), prolog scripts
   compute the union of resources allocated to all of a user's jobs on a
   node and apply corresponding systemd properties to the user slice:

   - ``AllowedCPUs`` - Restricts slice to allocated CPU cores
   - ``AllowedMemoryNodes`` - Restricts slice to NUMA nodes for allocated cores
   - ``DeviceAllow`` - Grants access only to allocated GPUs
   - ``DevicePolicy=closed`` - Blocks access to physical devices except those
     explicitly allowed

   When ``exec.sdexec-constrain-resources`` is disabled, prolog/housekeeping
   still manage the active marker and best-effort start/stop the user manager if
   ``pam.manage-user-slice`` is enabled, but do not apply resource constraints.

   See :core:man5:`flux-config-exec` for details on the ``exec`` configuration.


OPERATION
=========

Prolog Scripts
--------------

Prolog scripts run at job start and perform the following actions (when
``pam.manage-user-slice`` is enabled):

1. Acquire an exclusive lock for the user (prevents races between concurrent
   prolog/housekeeping operations)
2. Check that linger is not enabled for the user (fail hard if it is — see
   PREREQUISITES)
3. Count active jobs on the node for this user (excluding the starting job)
4. If ``exec.sdexec-constrain-resources`` is enabled:

   - Compute the union of resources from all active jobs (including the
     starting job)
   - Query ``sdexec-mapper`` for systemd properties corresponding to the
     resource union
   - Apply properties to ``user-UID.slice`` via ``systemctl set-property
     --runtime`` (stored even when the slice is inactive; applied when the
     first scope realizes the slice)

5. Create the per-user active marker file (``/run/flux-pam/uid.$UID.active``)
6. Best-effort start ``user@UID.service`` (see PROCFS WITH HIDEPID)
7. Release the lock

The slice itself is automatically realized by systemd  when the first login
session scope attaches.

Housekeeping Scripts
--------------------

Housekeeping scripts run at job completion and perform the following
actions (when ``pam.manage-user-slice`` is enabled):

1. Acquire an exclusive lock for the user
2. Count remaining active jobs on the node for this user (excluding the
   completed job)
3. If jobs remain (count > 0) and ``exec.sdexec-constrain-resources`` is
   enabled, recalculate and apply resource constraints for the remaining jobs
4. If no jobs remain (count = 0):

   - Clear the active marker (no new session will be admitted)
   - Best-effort stop ``user@UID.service`` (failure logged and ignored)
   - If ``pam.kill-user-slice`` is ``true``, perform cleanup sequence
     (see ``kill-user-slice`` above)
   - Revert the slice constraint drop-ins (``systemctl revert user-UID.slice``)

5. Release the lock

The empty slice goes dead and is garbage-collected automatically; there is no
need to explicitly stop the slice.


LOCKING AND SERIALIZATION
==========================

Prolog and housekeeping scripts acquire an exclusive lock (via ``flock``)
on ``/run/flux-pam/uid.UID.lock`` to serialize operations for each user.
This prevents race conditions when multiple jobs for the same user start
or complete concurrently on the same node.

The lock is held for the entire duration of prolog/housekeeping execution.
The active marker file is created and removed under this lock, and the PAM
session module reads it under lock, making session admission linearizable with
teardown.

The lock directory (``/run/flux-pam`` by default) must have permissions
``0700`` (owner read/write/execute only) and be owned by root. Lock files
within the directory are created with permissions ``0600`` (owner read/write
only) and are never deleted (they persist to avoid recreating them on each
operation). If the lock directory has group or other write permissions, both
the prolog/housekeeping scripts and the PAM session module will refuse to
proceed and log an error. The directory is created with correct permissions
at boot by the flux-pam tmpfiles.d drop-in (``/usr/lib/tmpfiles.d/flux-pam.conf``).


PROCFS WITH HIDEPID
===================

The ``hidepid=2`` mount option for ``/proc`` hides other users' processes.
This breaks ``systemd --user`` startup: the user manager must read
``/proc/1/cgroup`` to determine the cgroup root, but ``hidepid=2`` hides PID 1
from unprivileged users (systemd/systemd#12955). Red Hat documents ``hidepid``
as incompatible with the systemd user manager.

**flux-pam tolerates this.** The prolog makes service start best-effort (failure
is non-fatal). Containment depends on the slice, not the service: constraints
are applied with ``systemctl set-property --runtime`` (stored for inactive
slices) and enforced when the PAM module attaches the login scope. Logins work
even when ``user@$UID.service`` fails. Repeated service start failures in the
journal are expected and benign.

**Tradeoff:** No ``systemd --user`` instance means no ``systemctl --user``
units, user D-Bus, or user timers during jobs. This is normally acceptable on
batch compute nodes.

**Workaround (weakens hidepid):** To enable the user manager on ``hidepid=2``
nodes, add the ``gid=`` whitelisted group to ``user@.service``::

   # /etc/systemd/system/user@.service.d/hidepid.conf
   [Service]
   SupplementaryGroups=GROUP

Then ``systemctl daemon-reload``. This allows ``systemd --user`` to read
``/proc/1/cgroup``, but processes started via ``systemctl --user`` inherit the
group and can see all PIDs. Flux job processes are unaffected (run in separate
cgroup hierarchy).


SECURITY CONSIDERATIONS
=======================

User Isolation
--------------

When ``exec.sdexec-constrain-resources`` is enabled, systemd resource
constraints ensure that:

- Users can only access CPU cores allocated to their jobs
- Users can only access GPUs allocated to their jobs
- Users cannot access physical devices not explicitly granted

However, users in the same user slice (``user-UID.slice``) share these
constraints. All of a user's jobs on a node, plus any other processes the
user starts within ``user@UID.service`` (such as SSH sessions if permitted),
collectively share the union of resources allocated to the user's jobs.

Orphan Processes
----------------

With ``kill-user-slice = false`` (the default), processes that outlive a
user's jobs may remain in the user slice even after the slice is torn down at
the last job's completion. These processes may retain access to resources that
were allocated to previous jobs. Sites concerned about this should either:

- Enable ``kill-user-slice`` to forcibly terminate orphans
- Configure systemd's ``KillMode`` for user slices to handle cleanup
- Deploy separate mechanisms to detect and terminate orphan processes
- Use ``pam_flux.so`` account management to deny non-job logins entirely

EXAMPLES
========

Minimal configuration to enable user slice lifecycle management:

::

   [pam]
   manage-user-slice = true

Enable resource constraints (requires systemd execution service):

::

   [exec]
   service = "sdexec"
   sdexec-constrain-resources = true

   [pam]
   manage-user-slice = true

Enable aggressive orphan cleanup with 60-second grace time:

::

   [pam]
   manage-user-slice = true
   kill-user-slice = true
   kill-slice-grace-time = "60s"

Enable debug logging for prolog and housekeeping scripts:

::

   [pam]
   manage-user-slice = true
   debug = true


RESOURCES
=========

Flux Administrator's Guide: https://flux-framework.readthedocs.io/projects/flux-core/en/latest/guide/admin.html


SEE ALSO
========

:core:man5:`flux-config`,
:core:man5:`flux-config-exec`,
:core:man5:`flux-config-job-manager`,
`Flux Administrator's Guide: Adding Prolog/Housekeeping Scripts <https://flux-framework.readthedocs.io/projects/flux-core/en/latest/guide/admin_config.html#adding-prolog-epilog-housekeeping-scripts>`_,
:man8:`pam_flux`,
:linux:man5:`pam.d`
