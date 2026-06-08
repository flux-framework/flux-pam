###############################################################
# Copyright 2025 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

"""Helper functions for flux-pam prolog and housekeeping scripts."""

import errno
import fcntl
import os
import subprocess
import sys
import time

import flux
from flux.job import JobKVSLookup, JobList
from flux.resource import ResourceSet
from flux.util import parse_fsd


def acquire_lock(uid, timeout=60, lock_dir="/run/flux-pam"):
    """
    Acquire an exclusive lock for the given UID to serialize operations.

    Uses flock on <lock_dir>/uid.<UID>.lock with O_NOFOLLOW to prevent
    symlink attacks. Creates lock_dir if it doesn't exist.

    Args:
        uid: User ID to lock
        timeout: Maximum seconds to wait for lock (default: 60)
        lock_dir: Directory for lock files

    Returns:
        File descriptor of the lock file (caller should hold until done)

    Raises:
        OSError: If lock cannot be acquired within timeout
        ValueError: If lock path is a symlink
    """
    # Create lock directory if it doesn't exist
    os.makedirs(lock_dir, mode=0o700, exist_ok=True)

    # Verify directory is only writable by root (defense in depth)
    st = os.stat(lock_dir)
    if st.st_mode & 0o022:  # Check if group or other writable
        raise OSError(
            errno.EPERM,
            f"Lock directory {lock_dir} must not be group/other writable "
            f"(mode={oct(st.st_mode & 0o777)})",
        )

    lock_path = f"{lock_dir}/uid.{uid}.lock"

    # Open with O_NOFOLLOW to refuse symlinks
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise ValueError(f"Lock path {lock_path} is a symlink")
        raise

    # Try to acquire exclusive lock with timeout
    start = time.time()
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError as e:
            if e.errno != errno.EWOULDBLOCK:
                os.close(fd)
                raise
            if time.time() - start >= timeout:
                os.close(fd)
                raise OSError(
                    errno.ETIMEDOUT,
                    f"Could not acquire lock for uid {uid} within {timeout}s",
                )
            time.sleep(0.1)


def release_lock(fd):
    """
    Release a lock acquired by acquire_lock().

    Args:
        fd: File descriptor from acquire_lock()
    """
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def run_subprocess(args, timeout=30):
    """
    Run a subprocess with timeout, requiring absolute paths.

    Args:
        args: List of command arguments (first must be absolute path)
        timeout: Maximum seconds to wait (default: 30)

    Returns:
        subprocess.CompletedProcess result

    Raises:
        ValueError: If first argument is not an absolute path
        subprocess.TimeoutExpired: If command exceeds timeout
        subprocess.CalledProcessError: If command returns non-zero
    """
    if not args or not os.path.isabs(args[0]):
        raise ValueError(
            f"Command must use absolute path: {args[0] if args else '(empty)'}"
        )

    return subprocess.run(
        args,
        timeout=timeout,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )


class PAMHelper:
    """
    Helper class for managing systemd user slice resources via
    prolog/housekeeping.

    This class manages the lifecycle of systemd user services and applies
    resource constraints based on active flux jobs. It automatically
    acquires/releases locks and maintains flux connection state.
    """

    def __init__(
        self,
        userid,
        jobid,
        systemctl="/usr/bin/systemctl",
        loginctl="/usr/bin/loginctl",
    ):
        """
        Initialize a PAM helper for managing prolog/housekeeping actions.

        Args:
            userid: User ID to manage
            jobid: Current job ID (for exclusion from active job counts)
            systemctl: Path to systemctl binary
            loginctl: Path to loginctl binary

        Raises:
            OSError: If lock cannot be acquired
        """
        self.userid = userid
        self.jobid = jobid
        self.systemctl = systemctl
        self.loginctl = loginctl
        self._lock_fd = None
        self._cached_jobids = None
        self.handle = flux.Flux()
        self.rank = int(self.handle.attr_get("rank"))

        # Read all configuration upfront
        self._debug = (
            self.handle.conf_get("pam.debug", False)
            or os.environ.get("FLUX_PAM_SCRIPTS_DEBUG") is not None
        )

        self.manage_user_slice = self.handle.conf_get(
            "pam.manage-user-slice", False
        )
        self.apply_resources = self.handle.conf_get(
            "exec.sdexec-constrain-resources", False
        )
        self.kill_user_slice = self.handle.conf_get(
            "pam.kill-user-slice", False
        )
        self.kill_grace_time = parse_fsd(
            self.handle.conf_get("pam.kill-slice-grace-time", "30s")
        )

        # Set up lock directory and paths
        self._lock_dir = os.environ.get("FLUX_PAM_LOCK_DIR", "/run/flux-pam")
        self._marker_path = f"{self._lock_dir}/uid.{userid}.active"

        # Acquire lock for this user
        self._lock_fd = acquire_lock(userid, lock_dir=self._lock_dir)

    def __enter__(self):
        """Context manager entry."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - releases lock."""
        if self._lock_fd is not None:
            release_lock(self._lock_fd)
            self._lock_fd = None
        return False

    def should_skip(self):
        """
        Check if user slice management should be skipped for this user.

        User slice management includes both lifecycle (start/stop
        user@.service) and resource constraints. This method checks
        the master switch.

        Returns:
            True if this is the instance owner or feature is disabled
        """
        # Always skip instance owner
        owner_uid = int(self.handle.attr_get("security.owner"))
        if self.userid == owner_uid:
            return True

        # Check master switch (default: false, opt-in)
        return not self.manage_user_slice

    def check_linger(self, timeout=30):
        """
        Check if linger is enabled for this user.

        Uses loginctl to query the Linger property. Raises on timeout,
        unexpected failures, or unparsable output — fail-safe rather than
        silently allowing linger to go undetected.

        Args:
            timeout: Maximum seconds to wait (default: 30)

        Returns:
            True if linger is enabled, False if disabled

        Raises:
            subprocess.TimeoutExpired: If loginctl hangs
            ValueError: If loginctl fails unexpectedly or output is
                unparsable. "not logged in or lingering" is treated as
                a definitive False, not an error.
        """
        try:
            result = run_subprocess(
                [
                    self.loginctl,
                    "show-user",
                    str(self.userid),
                    "--property=Linger",
                ],
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            raise
        except subprocess.CalledProcessError as e:
            stderr = e.stderr.strip()
            if "not logged in or lingering" in stderr:
                return False
            raise ValueError(f"loginctl failed: {stderr}")

        output = result.stdout.strip()
        if output == "Linger=yes":
            return True
        elif output == "Linger=no":
            return False
        else:
            raise ValueError(f"Unexpected loginctl output: {output}")

    def active_local_jobs(self):
        """
        Get count of active jobs on this node for the current userid.

        Excludes self.jobid: for housekeeping the job is no longer active,
        for prolog the job is in RUN state but does not yet have a
        'start' event.

        Returns:
            Integer count of active jobs (excluding current job)
        """
        # Get all running jobs for this user
        jobs = JobList(
            self.handle,
            filters=["running"],
            user=str(self.userid),
            constraint={"ranks": [f"{self.rank}"]},
        ).jobs()

        # Filter to jobs on this rank, excluding current jobid
        self._cached_jobids = [job.id for job in jobs if job.id != self.jobid]

        return len(self._cached_jobids)

    def resource_union(self, include_current=False):
        """
        Compute union of resources from all active local jobs.

        Uses cached jobids from active_local_jobs() and fetches R from
        each job using JobKVSLookup.

        Args:
            include_current: If True, include self.jobid in the union
                (needed for prolog to include starting job's resources)

        Returns:
            ResourceSet object with merged resources or empty dict
        """
        if self._cached_jobids is None:
            raise RuntimeError("Must call active_local_jobs() first")

        jobids = self._cached_jobids
        if include_current:
            jobids = jobids + [self.jobid]

        if not jobids:
            return {}

        # Fetch R for all jobs
        union = None
        for result in JobKVSLookup(self.handle, jobids, "R").data():
            rset = ResourceSet(result["R"])
            if union is None:
                union = rset
            else:
                union = union.union(rset)

        return union

    def lookup_properties(self, R):
        """
        Look up systemd properties for given resources.

        Sends sdexec-mapper.lookup request with R and returns result.
        Caller should check should_skip() first to determine if feature
        is enabled.

        Args:
            R: Resource set (from resource_union())

        Returns:
            Dictionary of systemd properties, or empty dict on error
        """
        if not R:
            return {}

        try:
            return self.handle.rpc(
                "sdexec-mapper.lookup", {"R": R.encode()}
            ).get()
        except Exception as exc:
            print(f"sdexec-mapper.lookup: {exc}", file=sys.stderr)
            return {}

    def modify_slice(self, properties):
        """
        Apply slice properties to user slice via systemctl set-property.

        Args:
            properties: Dictionary of systemd properties
        """
        if not properties:
            return

        slice_name = f"user-{self.userid}.slice"
        args = [
            self.systemctl,
            "set-property",
            "--runtime",
            slice_name,
        ]

        for key, value in properties.items():
            args.append(f"{key}={value}")

        run_subprocess(args)

    def apply_resource_constraints(self, script_type, include_current=False):
        """
        Apply resource constraints to user slice based on active jobs.

        This is a convenience method for prolog/housekeeping scripts
        that combines: computing resource union, looking up systemd
        properties, and applying them to the slice.

        Only applies constraints if should_apply_resources() returns
        True.

        Args:
            script_type: Script name for debug logging ("prolog" or
                "housekeeping")
            include_current: If True, include self.jobid in resource
                union (needed for prolog to include starting job's
                resources)

        Example:
            # In prolog script (include starting job):
            helper.apply_resource_constraints(
                "prolog", include_current=True
            )

            # In housekeeping script (exclude ending job):
            helper.apply_resource_constraints("housekeeping")
        """
        if not self.apply_resources:
            self.debug_log(
                f"{script_type}: skipping resource constraints "
                "(exec.sdexec-constrain-resources not enabled)"
            )
            return

        # Compute resource union
        R = self.resource_union(include_current=include_current)
        self.debug_log(f"{script_type}: computed resource union: {R}")

        # Look up systemd properties for resources
        properties = self.lookup_properties(R)
        self.debug_log(
            f"{script_type}: lookup_properties returned {properties}"
        )

        # Apply properties to slice
        if properties:
            self.debug_log(
                f"{script_type}: applying {len(properties)} "
                f"properties to slice"
            )
            self.modify_slice(properties)
        else:
            self.debug_log(f"{script_type}: no properties to apply")

    def debug_log(self, msg):
        """Log a debug message prefixed with this job's ID."""
        if self._debug:
            print(f"flux-pam: {self.jobid}: {msg}", file=sys.stderr)

    def set_active_marker(self):
        """Create the per-user active marker.

        Called by the prolog after constraints are applied, under the user
        lock. Presence is the single source of truth the session module uses
        to admit logins. Idempotent. O_NOFOLLOW refuses symlinks.
        """
        fd = os.open(
            self._marker_path, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600
        )
        os.close(fd)

    def clear_active_marker(self):
        """Remove the per-user active marker. Idempotent."""
        try:
            os.unlink(self._marker_path)
        except FileNotFoundError:
            pass

    def revert_slice(self):
        """Remove Flux-applied resource-control drop-ins from the user slice.

        set-property --runtime stores a drop-in that persists until reboot or
        revert. Revert on last-job teardown so this job's constraints do not
        linger. Reverting a slice with no drop-ins is a no-op.
        """
        slice_name = f"user-{self.userid}.slice"
        try:
            run_subprocess([self.systemctl, "revert", slice_name])
        except subprocess.CalledProcessError as e:
            self.debug_log(f"slice revert non-fatal: {e.stderr.strip()}")

    def user_service_start(self):
        """Start systemd user service for this user."""
        service_name = f"user@{self.userid}.service"
        run_subprocess([self.systemctl, "start", service_name])

    def check_orphan_processes(self):
        """
        Check for orphan processes in user slice.

        Orphans are processes in user-$UID.slice that are not under
        user@$UID.service (e.g., leftover SSH sessions or other scopes).

        Returns:
            List of orphan process descriptions, or empty list if none
        """
        slice_path = f"/sys/fs/cgroup/user.slice/user-{self.userid}.slice"
        service_path = f"{slice_path}/user@{self.userid}.service"

        # Check if slice exists
        if not os.path.exists(slice_path):
            return []

        orphans = []
        # Walk the slice cgroup looking for non-service processes
        for root, dirs, files in os.walk(slice_path):
            # Skip the user@.service subtree
            if root.startswith(service_path):
                continue

            # Check for processes in this cgroup
            procs_file = os.path.join(root, "cgroup.procs")
            if os.path.exists(procs_file):
                try:
                    with open(procs_file) as f:
                        pids = [line.strip() for line in f if line.strip()]
                        if pids:
                            # Found orphan processes
                            scope = os.path.relpath(root, slice_path)
                            orphans.append(f"{scope}: {len(pids)} process(es)")
                except OSError:
                    pass

        return orphans

    def _wait_for_slice_empty(self, timeout):
        """
        Wait for user slice to become empty (no orphan processes).

        Polls check_orphan_processes() with exponential backoff starting
        at 10ms, capping at 500ms, until slice is empty or timeout expires.

        Args:
            timeout: Maximum seconds to wait

        Returns:
            True if slice became empty, False if timeout expired
        """
        start = time.time()
        interval = 0.01  # Start at 10ms

        while time.time() - start < timeout:
            if not self.check_orphan_processes():
                return True
            time.sleep(interval)
            interval = min(interval * 1.5, 0.5)  # Cap at 500ms

        return False

    def _kill_slice_processes(self, signal="SIGTERM"):
        """
        Send signal to all processes in user slice.

        Args:
            signal: Signal name (e.g., "SIGTERM", "SIGKILL")
        """
        slice_name = f"user-{self.userid}.slice"
        systemctl = self.systemctl
        run_subprocess([systemctl, "kill", f"--signal={signal}", slice_name])

    def _cleanup_user_slice(self):
        """
        Clean up user slice by killing all processes with grace time.

        Sends SIGTERM, waits for grace-time, sends SIGKILL, waits for
        grace-time again, then drains if processes remain.

        This implements the full cleanup sequence with configurable timeouts.

        Raises:
            RuntimeError: If processes remain after SIGKILL + grace-time
        """
        # Check if there are any orphan processes to kill
        orphans = self.check_orphan_processes()
        if not orphans:
            self.debug_log("No orphan processes in slice, cleanup not needed")
            return

        self.debug_log(
            f"Found {len(orphans)} orphan scope(s), starting cleanup"
        )
        self.debug_log(f"Using grace time: {self.kill_grace_time}s")

        # Step 1: Send SIGTERM
        self.debug_log("Sending SIGTERM to slice processes")
        self._kill_slice_processes(signal="SIGTERM")

        # Step 2: Wait for grace-time
        self.debug_log(
            f"Waiting {self.kill_grace_time}s for processes to exit"
        )
        if self._wait_for_slice_empty(self.kill_grace_time):
            self.debug_log("All processes exited after SIGTERM")
            return

        # Step 3: Send SIGKILL
        remaining = self.check_orphan_processes()
        self.debug_log(
            f"{len(remaining)} orphan scope(s) remain, sending SIGKILL"
        )
        self._kill_slice_processes(signal="SIGKILL")

        # Step 4: Wait for grace-time again
        self.debug_log(f"Waiting {self.kill_grace_time}s after SIGKILL")
        if self._wait_for_slice_empty(self.kill_grace_time):
            self.debug_log("All processes exited after SIGKILL")
            return

        # Step 5: Drain - processes still remain
        final_orphans = self.check_orphan_processes()
        msg = (
            f"Processes remain in user-{self.userid}.slice after "
            f"SIGKILL + {self.kill_grace_time}s grace time: "
            f"{', '.join(final_orphans)}"
        )
        raise RuntimeError(msg)

    def user_slice_teardown(self):
        """Tear down user slice on the user's last job.

        Clear the active marker first so no new session is admitted,
        best-effort stop the user manager (it may have failed to start,
        e.g. due to /proc mounted with hidepid=2), run the configured
        orphan cleanup, then revert the constraint drop-ins. The empty
        slice goes dead and is garbage-collected automatically; there is
        no slice to stop.
        """
        self.clear_active_marker()
        service_name = f"user@{self.userid}.service"
        try:
            run_subprocess([self.systemctl, "stop", service_name])
        except subprocess.CalledProcessError as e:
            self.debug_log(f"user manager stop non-fatal: {e.stderr.strip()}")

        cleanup_error = None
        if self.kill_user_slice:
            self.debug_log("kill-user-slice enabled, cleaning up slice")
            try:
                self._cleanup_user_slice()
            except RuntimeError as e:
                cleanup_error = e

        self.revert_slice()

        if cleanup_error:
            raise cleanup_error


# vi: sw=4 ts=4 expandtab
