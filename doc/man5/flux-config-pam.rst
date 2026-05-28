====================
flux-config-pam(5)
====================


DESCRIPTION
===========

The ``pam`` table configures flux-pam features that manage systemd user
slices for Flux job users. This includes:

- The flux-pam prolog and housekeeping scripts, which run during job prolog
  and housekeeping phases to start/stop user services and optionally apply
  resource constraints to user slices.
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

When ``pam.manage-user-slice`` is enabled, Flux takes ownership of the
``user@UID.service`` manager for job users — starting it at first job and
stopping it after the last. **systemd linger must not be enabled for job
users on compute nodes.** Linger (``loginctl enable-linger``) keeps
``user@UID.service`` running independently of jobs, which interferes with
Flux's lifecycle management in ways that can cause login sessions to escape
containment silently. The prolog will fail hard if it detects linger is
enabled for a job user, rather than proceeding with an inconsistent state.

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
   Boolean value that enables systemd user slice lifecycle
   management via prolog and housekeeping scripts. When enabled, the
   prolog starts ``user@UID.service`` (if not already running) for each
   job user, and housekeeping stops it when the user's last job completes.
   This is the master switch for all user slice management features,
   including session attachment in ``pam_flux.so`` (see :man8:`pam_flux`).
   (Default: ``false``).

   When this feature is disabled, prolog and housekeeping scripts exit
   early without managing user services or applying resource constraints.
   This includes the instance owner (who always skips management).

kill-user-slice
   Boolean value that controls whether housekeeping actively terminates
   processes remaining in the user slice when stopping
   ``user@UID.service``. (Default: ``false``).

   When set to ``true``, housekeeping implements aggressive cleanup:

   - Checks for orphan processes (processes in ``user-UID.slice`` but not
     under ``user@UID.service``, such as leftover SSH sessions or other
     systemd scopes)
   - If orphans exist, sends ``SIGTERM`` to all processes in the slice
   - Waits for ``kill-slice-grace-time`` for processes to exit
   - If processes remain, sends ``SIGKILL`` to all processes in the slice
   - Waits for ``kill-slice-grace-time`` again
   - If processes still remain, raises an error and drains the node

   When set to ``false`` (the default), housekeeping stops
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
   still manage the user service lifecycle (start/stop) if
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
4. Start ``user@UID.service`` (idempotent: no-op if already running due to
   a concurrent prolog for the same user)
5. If ``exec.sdexec-constrain-resources`` is enabled:

   - Compute the union of resources from all active jobs (including the
     starting job)
   - Query ``sdexec-mapper`` for systemd properties corresponding to the
     resource union
   - Apply properties to ``user-UID.slice`` via ``systemctl set-property``

6. Release the lock

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

   - If ``pam.kill-user-slice`` is ``true``, perform cleanup sequence
     (see ``kill-user-slice`` above)
   - Stop ``user@UID.service``

5. Release the lock


LOCKING AND SERIALIZATION
==========================

Prolog and housekeeping scripts acquire an exclusive lock (via ``flock``)
on ``/run/flux-pam/uid.UID.lock`` to serialize operations for each user.
This prevents race conditions when multiple jobs for the same user start
or complete concurrently on the same node.

The lock is held for the entire duration of prolog/housekeeping execution
and released automatically when the script exits.

The lock directory (``/run/flux-pam`` by default) must have permissions
``0700`` (owner read/write/execute only) and be owned by root. Lock files
within the directory are created with permissions ``0600`` (owner read/write
only) and are never deleted (they persist to avoid recreating them on each
operation). If the lock directory has group or other write permissions, both
the prolog/housekeeping scripts and the PAM session module will refuse to
proceed and log an error. The directory is created with correct permissions
at boot by the flux-pam tmpfiles.d drop-in (``/usr/lib/tmpfiles.d/flux-pam.conf``).


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
user's jobs may remain in the user slice even after ``user@UID.service``
stops. These processes may retain access to resources that were allocated
to previous jobs. Sites concerned about this should either:

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
