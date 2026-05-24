#!/usr/bin/env python3

###############################################################
# Copyright 2025 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

import errno
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import flux
import flux.job
import flux.pam
from subflux import rerun_under_flux


def __flux_size():
    return 4


class TestLocking(unittest.TestCase):
    """Test lock acquisition and release."""

    def setUp(self):
        """Create temp directory for lock tests"""
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        """Clean up temp directory"""

        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_acquire_lock(self):
        """Test basic lock acquisition"""
        fd = flux.pam.acquire_lock(os.getuid(), lock_dir=self.tmpdir)
        self.assertIsNotNone(fd)
        self.assertGreater(fd, 0)
        flux.pam.release_lock(fd)

    def test_lock_reentrant_fails(self):
        """Test that acquiring same lock twice fails"""
        fd = flux.pam.acquire_lock(
            os.getuid(), timeout=2, lock_dir=self.tmpdir
        )
        self.assertIsNotNone(fd)

        # Second acquire should timeout
        with self.assertRaises(OSError) as ctx:
            flux.pam.acquire_lock(os.getuid(), timeout=1, lock_dir=self.tmpdir)
        self.assertEqual(ctx.exception.errno, errno.ETIMEDOUT)

        flux.pam.release_lock(fd)

    def test_lock_refuses_symlink(self):
        """Test that lock refuses symlink paths"""
        uid = os.getuid()
        lock_path = f"{self.tmpdir}/uid.{uid}.lock"

        # Create a symlink at the lock path
        os.symlink("/tmp/fake", lock_path)

        # This should fail because lock_path is a symlink
        with self.assertRaises(ValueError) as ctx:
            flux.pam.acquire_lock(uid, lock_dir=self.tmpdir)
        self.assertIn("symlink", str(ctx.exception))

    def test_lock_refuses_group_writable_dir(self):
        """Test that lock refuses group-writable directory"""
        uid = os.getuid()

        # Make directory group-writable
        os.chmod(self.tmpdir, 0o770)

        # Should fail because directory is group-writable
        with self.assertRaises(OSError) as ctx:
            flux.pam.acquire_lock(uid, lock_dir=self.tmpdir)
        self.assertEqual(ctx.exception.errno, errno.EPERM)
        self.assertIn("group/other writable", str(ctx.exception))

    def test_lock_refuses_other_writable_dir(self):
        """Test that lock refuses other-writable directory"""
        uid = os.getuid()

        # Make directory other-writable
        os.chmod(self.tmpdir, 0o707)

        # Should fail because directory is other-writable
        with self.assertRaises(OSError) as ctx:
            flux.pam.acquire_lock(uid, lock_dir=self.tmpdir)
        self.assertEqual(ctx.exception.errno, errno.EPERM)
        self.assertIn("group/other writable", str(ctx.exception))

    def test_lock_accepts_owner_only_writable_dir(self):
        """Test that lock accepts owner-only writable directory"""
        uid = os.getuid()

        # Make directory owner-only writable (0700)
        os.chmod(self.tmpdir, 0o700)

        # Should succeed
        fd = flux.pam.acquire_lock(uid, lock_dir=self.tmpdir)
        self.assertIsNotNone(fd)
        self.assertGreater(fd, 0)
        flux.pam.release_lock(fd)

    def test_lock_creates_dir_with_correct_permissions(self):
        """Test that acquire_lock creates directory with mode 0700"""
        uid = os.getuid()
        new_dir = os.path.join(self.tmpdir, "new_lock_dir")

        # Directory should not exist yet
        self.assertFalse(os.path.exists(new_dir))

        # Acquire lock should create it
        fd = flux.pam.acquire_lock(uid, lock_dir=new_dir)
        self.assertTrue(os.path.exists(new_dir))

        # Verify it was created with mode 0700
        st = os.stat(new_dir)
        mode = st.st_mode & 0o777
        self.assertEqual(mode, 0o700, f"Expected 0700, got {oct(mode)}")

        flux.pam.release_lock(fd)

    def test_lock_file_created_with_correct_permissions(self):
        """Test that lock file is created with mode 0600"""
        uid = os.getuid()

        # Ensure directory has correct permissions
        os.chmod(self.tmpdir, 0o700)

        # Acquire lock
        fd = flux.pam.acquire_lock(uid, lock_dir=self.tmpdir)

        # Check lock file permissions
        lock_path = f"{self.tmpdir}/uid.{uid}.lock"
        st = os.stat(lock_path)
        mode = st.st_mode & 0o777
        self.assertEqual(mode, 0o600, f"Expected 0600, got {oct(mode)}")

        flux.pam.release_lock(fd)


class TestSubprocess(unittest.TestCase):
    """Test subprocess execution."""

    def test_run_subprocess_basic(self):
        """Test basic subprocess execution"""
        result = flux.pam.run_subprocess(["/bin/true"])
        self.assertEqual(result.returncode, 0)

    def test_run_subprocess_requires_absolute_path(self):
        """Test that relative paths are rejected"""
        with self.assertRaises(ValueError) as ctx:
            flux.pam.run_subprocess(["true"])
        self.assertIn("absolute path", str(ctx.exception))

    def test_run_subprocess_timeout(self):
        """Test subprocess timeout"""
        with self.assertRaises(subprocess.TimeoutExpired):
            flux.pam.run_subprocess(["/bin/sleep", "10"], timeout=0.5)

    def test_run_subprocess_failure(self):
        """Test subprocess with non-zero exit"""
        with self.assertRaises(subprocess.CalledProcessError):
            flux.pam.run_subprocess(["/bin/false"])

    def test_run_subprocess_capture_output(self):
        """Test subprocess output capture"""
        result = flux.pam.run_subprocess(["/bin/echo", "test"])
        self.assertEqual(result.stdout.strip(), "test")


class TestPAMHelper(unittest.TestCase):
    """Test PAMHelper class."""

    def test_helper_context_manager(self):
        """Test PAMHelper as context manager"""
        uid = os.getuid()
        jobid = 12345

        # Set temp lock dir for testing
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, jobid) as helper:
                self.assertEqual(helper.userid, uid)
                self.assertEqual(helper.jobid, jobid)
                self.assertIsNotNone(helper.handle)
                self.assertGreaterEqual(helper.rank, 0)
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_should_skip_instance_owner(self):
        """Test that instance owner is skipped"""
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            handle = flux.Flux()
            owner_uid = int(handle.attr_get("security.owner"))

            with flux.pam.PAMHelper(owner_uid, 12345) as helper:
                self.assertTrue(helper.should_skip())
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_active_local_jobs_excludes_current(self):
        """Test that active_local_jobs excludes current jobid"""
        uid = os.getuid()
        jobid = 99999999  # Non-existent job

        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, jobid) as helper:
                # Should return 0 since we have no running jobs as this user
                count = helper.active_local_jobs()
                self.assertGreaterEqual(count, 0)
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_should_skip_when_disabled(self):
        """Test that should_skip checks pam.manage-user-slice config"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                owner_uid = int(helper.handle.attr_get("security.owner"))

                # Mock conf_get to check correct key and return False
                def mock_conf_get_disabled(key, default):
                    if key == "pam.manage-user-slice":
                        return False
                    return default

                with patch.object(
                    helper.handle,
                    "conf_get",
                    side_effect=mock_conf_get_disabled,
                ):
                    self.assertTrue(helper.should_skip())

                # Mock conf_get to return True (enabled)
                def mock_conf_get_enabled(key, default):
                    if key == "pam.manage-user-slice":
                        return True
                    return default

                with patch.object(
                    helper.handle,
                    "conf_get",
                    side_effect=mock_conf_get_enabled,
                ):
                    # Should not skip (unless we're instance owner)
                    if uid != owner_uid:
                        self.assertFalse(helper.should_skip())
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_should_apply_resources(self):
        """
        Test should_apply_resources checks exec.sdexec-constrain-resources
        """
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock conf_get to return False for sdexec-constrain-resources
                def mock_conf_get_no_resources(key, default):
                    if key == "exec.sdexec-constrain-resources":
                        return False
                    return default

                with patch.object(
                    helper.handle,
                    "conf_get",
                    side_effect=mock_conf_get_no_resources,
                ):
                    self.assertFalse(helper.should_apply_resources())

                # Mock conf_get to return True for sdexec-constrain-resources
                def mock_conf_get_with_resources(key, default):
                    if key == "exec.sdexec-constrain-resources":
                        return True
                    return default

                with patch.object(
                    helper.handle,
                    "conf_get",
                    side_effect=mock_conf_get_with_resources,
                ):
                    self.assertTrue(helper.should_apply_resources())
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union_before_active_jobs(self):
        """Test resource_union raises if called before active_local_jobs"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Should raise since we haven't called active_local_jobs yet
                with self.assertRaises(RuntimeError) as ctx:
                    helper.resource_union()
                self.assertIn("active_local_jobs", str(ctx.exception))
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union_empty(self):
        """Test that resource_union returns {} when no jobs"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Call active_local_jobs first (will return 0)
                count = helper.active_local_jobs()
                self.assertEqual(count, 0)

                # resource_union should return empty dict
                R = helper.resource_union()
                self.assertEqual(R, {})
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_lookup_properties_rpc_failure(self):
        """Test lookup_properties returns {} when RPC fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock rpc to raise exception
                with patch.object(
                    helper.handle,
                    "rpc",
                    side_effect=OSError("RPC failed"),
                ):
                    props = helper.lookup_properties({"some": "R"})
                    self.assertEqual(props, {})
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_modify_slice_empty_properties(self):
        """Test modify_slice returns early with empty properties"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Should not raise, just return
                helper.modify_slice({})
                helper.modify_slice(None)
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]


class TestPAMHelperWithJobs(unittest.TestCase):
    """Test PAMHelper with actual running jobs."""

    @classmethod
    def setUpClass(cls):
        """Submit test jobs on different ranks"""
        try:
            cls.handle = flux.Flux()
            cls.uid = os.getuid()
            cls.jobids = []
            cls.tmpdir = tempfile.mkdtemp()

            # Submit one job per rank to avoid core contention
            # Submit job on rank 0
            jobspec = flux.job.JobspecV1.from_submit(
                command=["sleep", "300"],
                ntasks=1,
                nodes=1,
                requires="rank:0",
            )
            cls.jobids.append(flux.job.submit(cls.handle, jobspec))

            # Submit job on rank 1
            jobspec = flux.job.JobspecV1.from_submit(
                command=["sleep", "300"],
                ntasks=1,
                nodes=1,
                requires="rank:1",
            )
            cls.jobids.append(flux.job.submit(cls.handle, jobspec))

            # Submit job on rank 2
            jobspec = flux.job.JobspecV1.from_submit(
                command=["sleep", "300"],
                ntasks=1,
                nodes=1,
                requires="rank:2",
            )
            cls.jobids.append(flux.job.submit(cls.handle, jobspec))

            # Wait for jobs to start running
            for jobid in cls.jobids:
                flux.job.event_wait(cls.handle, jobid, "start")

            # Verify we got all jobs running
            running_jobs = list(
                flux.job.JobList(cls.handle, filters=["running"]).jobs()
            )
            if len(running_jobs) < 3:
                raise RuntimeError(f"Only {len(running_jobs)}/3 jobs started")
        except Exception as e:
            print(f"setUpClass failed: {e}")
            import traceback

            traceback.print_exc()
            raise

    @classmethod
    def tearDownClass(cls):
        """Cancel test jobs"""
        for jobid in cls.jobids:
            try:
                flux.job.cancel(cls.handle, jobid)
            except Exception:
                pass

        shutil.rmtree(cls.tmpdir, ignore_errors=True)

    def test_active_jobs_filters_by_rank(self):
        """Test that active_local_jobs counts running jobs"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            # First check: do we have any running jobs at all?
            all_jobs = list(
                flux.job.JobList(self.handle, filters=["running"]).jobs()
            )
            # We submitted 3 jobs, so there should be 3 running
            self.assertGreaterEqual(len(all_jobs), 1, "No running jobs found")

            # Now test PAMHelper
            with flux.pam.PAMHelper(self.uid, 99999999) as helper:
                count = helper.active_local_jobs()
                # Should see at least 1 job
                self.assertGreaterEqual(count, 1)
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_active_jobs_excludes_specified_jobid(self):
        """Test that active_local_jobs excludes the specified jobid"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            # On rank 2, exclude one of the two jobs
            with flux.pam.PAMHelper(self.uid, self.jobids[1]) as helper:
                if helper.rank == 2:
                    count = helper.active_local_jobs()
                    # Should see 1 job (the other one on rank 2)
                    self.assertEqual(count, 1)
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union(self):
        """Test that resource_union computes correct union"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            with flux.pam.PAMHelper(self.uid, 99999999) as helper:
                count = helper.active_local_jobs()

                if count > 0:
                    # Get resource union
                    R = helper.resource_union()
                    self.assertIsNotNone(R)
                    # Should have some resource data
                    self.assertTrue(R.nnodes > 0)
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union_include_current(self):
        """Test resource_union with include_current=True"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            # Use one of our actual running jobs
            with flux.pam.PAMHelper(self.uid, self.jobids[0]) as helper:
                count = helper.active_local_jobs()
                # Should exclude jobids[0]
                self.assertGreaterEqual(count, 0)

                # Get union without current job
                R_without = helper.resource_union()

                # Get union with current job
                R_with = helper.resource_union(include_current=True)

                # With current should have more resources
                if count == 0:
                    # If no other jobs, R_without is empty
                    self.assertEqual(R_without, {})
                    # But R_with should have the current job's resources
                    self.assertNotEqual(R_with, {})
                    self.assertTrue(R_with.nnodes > 0)
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]


class TestCheckLinger(unittest.TestCase):
    """Test PAMHelper.check_linger() instance method."""

    LOGINCTL = "/test/loginctl"

    def _make_helper(self):
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        return flux.pam.PAMHelper(uid, 12345, loginctl=self.LOGINCTL)

    def _cleanup_helper(self, helper):
        helper.__exit__(None, None, None)
        shutil.rmtree(os.environ.pop("FLUX_PAM_LOCK_DIR"), ignore_errors=True)

    def test_check_linger_enabled(self):
        """check_linger returns True when linger is enabled"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="Linger=yes\n", stderr=""
                )
                self.assertTrue(helper.check_linger())
        finally:
            self._cleanup_helper(helper)

    def test_check_linger_disabled(self):
        """check_linger returns False when linger is disabled"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="Linger=no\n", stderr=""
                )
                self.assertFalse(helper.check_linger())
        finally:
            self._cleanup_helper(helper)

    def test_check_linger_timeout(self):
        """check_linger raises TimeoutExpired on loginctl timeout"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.side_effect = subprocess.TimeoutExpired(
                    ["loginctl"], 30
                )
                with self.assertRaises(subprocess.TimeoutExpired):
                    helper.check_linger()
        finally:
            self._cleanup_helper(helper)

    def test_check_linger_command_failure(self):
        """check_linger raises ValueError on unexpected loginctl failure"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.side_effect = subprocess.CalledProcessError(
                    1, ["loginctl"], stderr="User not found"
                )
                with self.assertRaises(ValueError):
                    helper.check_linger()
        finally:
            self._cleanup_helper(helper)

    def test_check_linger_unparsable(self):
        """check_linger raises ValueError on unparsable output"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="Invalid output\n", stderr=""
                )
                with self.assertRaises(ValueError):
                    helper.check_linger()
        finally:
            self._cleanup_helper(helper)

    def test_check_linger_uses_configured_loginctl(self):
        """check_linger invokes the loginctl path given to PAMHelper"""
        helper = self._make_helper()
        try:
            with patch("flux.pam.run_subprocess") as mock_run:
                mock_run.return_value = subprocess.CompletedProcess(
                    args=[], returncode=0, stdout="Linger=no\n", stderr=""
                )
                helper.check_linger()
                args = mock_run.call_args[0][0]
                self.assertEqual(args[0], self.LOGINCTL)
        finally:
            self._cleanup_helper(helper)


class TestPAMHelperErrors(unittest.TestCase):
    """Test error handling in PAMHelper methods."""

    def test_lock_directory_creation_failure(self):
        """Test acquire_lock when directory can't be created"""
        # Use a path that can't be created (under /dev/null)
        with self.assertRaises(OSError):
            flux.pam.acquire_lock(12345, lock_dir="/dev/null/impossible")

    def test_lock_file_is_directory(self):
        """Test acquire_lock when lock path exists as directory"""
        tmpdir = tempfile.mkdtemp()
        try:
            uid = os.getuid()
            lock_path = f"{tmpdir}/uid.{uid}.lock"
            # Create lock_path as a directory
            os.mkdir(lock_path)

            # Should fail because lock_path is a directory
            with self.assertRaises((OSError, ValueError)):
                flux.pam.acquire_lock(uid, lock_dir=tmpdir)
        finally:

            shutil.rmtree(tmpdir, ignore_errors=True)

    def test_active_local_jobs_rpc_failure(self):
        """Test active_local_jobs when JobList RPC fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock JobList to raise exception
                with patch("flux.pam.JobList") as mock_joblist:
                    mock_joblist.side_effect = OSError("RPC failed")

                    # Should raise exception
                    with self.assertRaises(OSError):
                        helper.active_local_jobs()
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union_jobkvslookup_failure(self):
        """Test resource_union when JobKVSLookup fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Set cached jobids to simulate active_local_jobs was called
                helper._cached_jobids = [flux.job.JobID(99999)]

                # Mock JobKVSLookup to raise exception
                with patch("flux.pam.JobKVSLookup") as mock_lookup:
                    mock_lookup.side_effect = OSError("KVS lookup failed")

                    # Should raise exception
                    with self.assertRaises(OSError):
                        helper.resource_union()
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_resource_union_invalid_R_data(self):
        """Test resource_union when R data can't be parsed"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Set cached jobids
                helper._cached_jobids = [flux.job.JobID(99999)]

                # Mock JobKVSLookup to return invalid R
                with patch("flux.pam.JobKVSLookup") as mock_lookup:
                    mock_instance = mock_lookup.return_value
                    mock_instance.data.return_value = [{"R": "invalid"}]

                    # Should raise exception from ResourceSet
                    with self.assertRaises(Exception):
                        helper.resource_union()
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_modify_slice_systemctl_failure(self):
        """Test modify_slice when systemctl command fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock run_subprocess to raise exception
                with patch("flux.pam.run_subprocess") as mock_run:
                    mock_run.side_effect = subprocess.CalledProcessError(
                        1, ["systemctl"], stderr="Failed to set property"
                    )

                    # Should raise exception
                    with self.assertRaises(subprocess.CalledProcessError):
                        helper.modify_slice({"CPUAccounting": "yes"})
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_user_service_start_failure(self):
        """Test user_service_start when systemctl fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock run_subprocess to raise exception
                with patch("flux.pam.run_subprocess") as mock_run:
                    mock_run.side_effect = subprocess.CalledProcessError(
                        1, ["systemctl", "start"], stderr="Service not found"
                    )

                    # Should raise exception
                    with self.assertRaises(subprocess.CalledProcessError):
                        helper.user_service_start()
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_user_service_stop_failure(self):
        """Test user_service_stop when systemctl fails"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock run_subprocess to raise exception
                with patch("flux.pam.run_subprocess") as mock_run:
                    mock_run.side_effect = subprocess.CalledProcessError(
                        1, ["systemctl", "stop"], stderr="Service not found"
                    )

                    # Should raise exception
                    with self.assertRaises(subprocess.CalledProcessError):
                        helper.user_service_stop()
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_modify_slice_includes_all_properties(self):
        """Test modify_slice passes all properties to systemctl set-property"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(uid, 12345) as helper:
                # Mock run_subprocess to capture arguments
                with patch("flux.pam.run_subprocess") as mock_run:
                    properties = {
                        "AllowedCPUs": "0-3",
                        "DevicePolicy": "closed",
                        "DeviceAllow": "/dev/nvidia0 rw",
                    }
                    helper.modify_slice(properties)

                    # Should be called exactly once — device properties go
                    # through systemctl set-property, not a separate helper
                    self.assertEqual(mock_run.call_count, 1)

                    args = mock_run.call_args[0][0]
                    args_str = " ".join(args)
                    self.assertIn("AllowedCPUs", args_str)
                    self.assertIn("DevicePolicy", args_str)
                    self.assertIn("DeviceAllow", args_str)
        finally:

            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_systemctl_path_is_used(self):
        """Test PAMHelper uses the systemctl path given to constructor"""
        uid = os.getuid()
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with flux.pam.PAMHelper(
                uid, 12345, systemctl="/test/mock-systemctl"
            ) as helper:
                self.assertEqual(helper.systemctl, "/test/mock-systemctl")
        finally:
            shutil.rmtree(
                os.environ.pop("FLUX_PAM_LOCK_DIR"), ignore_errors=True
            )


class TestPAMHelperWithMapper(unittest.TestCase):
    """Test PAMHelper with real sdexec-mapper module."""

    @classmethod
    def setUpClass(cls):
        """Load sdexec-mapper module and submit test job"""
        try:
            cls.handle = flux.Flux()
            cls.uid = os.getuid()
            cls.tmpdir = tempfile.mkdtemp()

            # Load sdexec-mapper module
            cls.handle.rpc(
                "module.load",
                {"path": "sdexec-mapper", "args": [], "exec": False},
            ).get()

            # Submit a test job. Use all 4 nodes so that the job is always
            # running on rank 0 (the current rank)
            jobspec = flux.job.JobspecV1.from_submit(
                command=["sleep", "300"],
                ntasks=4,
                nodes=4,
            )
            cls.jobid = flux.job.submit(cls.handle, jobspec)
            flux.job.event_wait(cls.handle, cls.jobid, "start")

        except Exception as e:
            print(f"setUpClass failed: {e}")
            import traceback

            traceback.print_exc()
            raise

    @classmethod
    def tearDownClass(cls):
        """Cancel test job and unload sdexec-mapper"""
        try:
            flux.job.cancel(cls.handle, cls.jobid)
        except Exception:
            pass

        try:
            cls.handle.rpc("module.remove", {"name": "sdexec-mapper"}).get()
        except Exception:
            pass

        shutil.rmtree(cls.tmpdir, ignore_errors=True)

    def test_lookup_properties_with_mapper(self):
        """Test lookup_properties returns expected systemd properties"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            with flux.pam.PAMHelper(self.uid, self.jobid) as helper:
                # Get resource union for this job
                helper.active_local_jobs()
                R = helper.resource_union(include_current=True)

                # Should get some resources
                self.assertNotEqual(R, {})

                # Lookup properties from mapper
                properties = helper.lookup_properties(R)

                # Should get properties back as a dict
                self.assertIsNotNone(properties)
                self.assertIsInstance(properties, dict)

                # Should have at least some properties for valid resources
                self.assertTrue(len(properties) > 0)

                # Should include AllowedCPUs
                self.assertIn("AllowedCPUs", properties)
                # AllowedCPUs should be a non-empty string
                self.assertIsInstance(properties["AllowedCPUs"], str)
                self.assertTrue(len(properties["AllowedCPUs"]) > 0)
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_lookup_properties_empty_R(self):
        """Test lookup_properties with empty R returns empty dict"""
        os.environ["FLUX_PAM_LOCK_DIR"] = self.tmpdir

        try:
            with flux.pam.PAMHelper(self.uid, self.jobid) as helper:
                # Call with empty R
                properties = helper.lookup_properties({})
                self.assertEqual(properties, {})
        finally:
            del os.environ["FLUX_PAM_LOCK_DIR"]


class TestApplyResourceConstraints(unittest.TestCase):
    """Test apply_resource_constraints helper method"""

    def test_apply_resource_constraints_includes_current(self):
        """Test apply_resource_constraints with include_current=True"""
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                # Mock should_apply_resources to return True
                helper.handle.conf_get = lambda key, default: (
                    True
                    if key == "exec.sdexec-constrain-resources"
                    else default
                )

                # Mock the methods that will be called
                with patch.object(
                    helper, "resource_union", return_value={"mock": "R"}
                ) as mock_union:
                    with patch.object(
                        helper,
                        "lookup_properties",
                        return_value={"CPUAccounting": "yes"},
                    ) as mock_lookup:
                        with patch.object(
                            helper, "modify_slice"
                        ) as mock_modify:
                            # Call with include_current=True
                            helper.apply_resource_constraints(
                                "prolog", include_current=True
                            )

                            # Verify resource_union called with
                            # include_current=True
                            mock_union.assert_called_once_with(
                                include_current=True
                            )
                            # Verify lookup_properties called with R
                            mock_lookup.assert_called_once_with({"mock": "R"})
                            # Verify modify_slice called with properties
                            mock_modify.assert_called_once_with(
                                {"CPUAccounting": "yes"}
                            )
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_apply_resource_constraints_excludes_current(self):
        """Test apply_resource_constraints with include_current=False"""
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                helper.handle.conf_get = lambda key, default: (
                    True
                    if key == "exec.sdexec-constrain-resources"
                    else default
                )

                with patch.object(
                    helper, "resource_union", return_value={"mock": "R"}
                ) as mock_union:
                    with patch.object(
                        helper,
                        "lookup_properties",
                        return_value={"CPUAccounting": "yes"},
                    ):
                        with patch.object(helper, "modify_slice"):
                            # Call with include_current=False (default)
                            helper.apply_resource_constraints("housekeeping")

                            # Verify resource_union called with
                            # include_current=False
                            mock_union.assert_called_once_with(
                                include_current=False
                            )
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_apply_resource_constraints_skips_when_disabled(self):
        """Test apply_resource_constraints respects should_apply_resources"""
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                # Mock should_apply_resources to return False
                helper.handle.conf_get = lambda key, default: False

                with patch.object(helper, "resource_union") as mock_union:
                    with patch.object(
                        helper, "lookup_properties"
                    ) as mock_lookup:
                        with patch.object(
                            helper, "modify_slice"
                        ) as mock_modify:
                            # Call helper
                            helper.apply_resource_constraints("prolog")

                            # Verify none of the methods were called
                            mock_union.assert_not_called()
                            mock_lookup.assert_not_called()
                            mock_modify.assert_not_called()
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_apply_resource_constraints_with_empty_properties(self):
        """Test apply_resource_constraints when no properties returned"""
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                helper.handle.conf_get = lambda key, default: (
                    True
                    if key == "exec.sdexec-constrain-resources"
                    else default
                )

                with patch.object(helper, "resource_union", return_value={}):
                    # lookup_properties returns empty dict (no mapper)
                    with patch.object(
                        helper, "lookup_properties", return_value={}
                    ):
                        with patch.object(
                            helper, "modify_slice"
                        ) as mock_modify:
                            helper.apply_resource_constraints("housekeeping")

                            # modify_slice should not be called with
                            # empty properties
                            mock_modify.assert_not_called()
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]


class TestKillUserSlice(unittest.TestCase):
    """Test kill-user-slice functionality"""

    def test_kill_user_slice_no_orphans_skips_cleanup(self):
        """
        Test user_service_stop when no orphans exist
        """
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                # Mock conf_get
                def mock_conf_get(key, default):
                    if key == "pam.kill-user-slice":
                        return True
                    return default

                helper.handle.conf_get = mock_conf_get

                # No orphans - cleanup should be skipped
                with patch.object(
                    helper, "check_orphan_processes", return_value=[]
                ):
                    with patch("flux.pam.run_subprocess") as mock_run:
                        helper.user_service_stop()

                        # Should only call stop (no kill since no orphans)
                        self.assertEqual(mock_run.call_count, 1)
                        call_str = str(mock_run.call_args_list[0])
                        self.assertIn("stop", call_str)
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_kill_user_slice_with_orphans_sigterm_succeeds(self):
        """
        Test cleanup when orphans exit after SIGTERM
        """
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                def mock_conf_get(key, default):
                    if key == "pam.kill-user-slice":
                        return True
                    if key == "pam.kill-slice-grace-time":
                        return "0.1s"  # Fast timeout for tests
                    return default

                helper.handle.conf_get = mock_conf_get

                # First call: orphans exist, then they're gone
                orphan_calls = [["scope1"], []]
                with patch.object(
                    helper,
                    "check_orphan_processes",
                    side_effect=orphan_calls,
                ):
                    with patch("flux.pam.run_subprocess") as mock_run:
                        helper.user_service_stop()

                        # Should call kill (SIGTERM) then stop
                        self.assertEqual(mock_run.call_count, 2)
                        calls = [str(call) for call in mock_run.call_args_list]
                        self.assertTrue(
                            any("SIGTERM" in c for c in calls),
                            "Should send SIGTERM",
                        )
                        self.assertTrue(
                            any("stop" in c for c in calls),
                            "Should stop service",
                        )
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_kill_user_slice_config_false_ignores_orphans(self):
        """
        Test user_service_stop with kill-user-slice=false just stops service

        When kill=false, cleanup is delegated elsewhere, so we ignore orphans
        and just stop the service.
        """
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                # Mock conf_get to return false for kill-user-slice
                def mock_conf_get(key, default):
                    if key == "pam.kill-user-slice":
                        return False
                    return default

                helper.handle.conf_get = mock_conf_get

                # Mock check_orphan_processes - should NOT be called
                with patch.object(
                    helper,
                    "check_orphan_processes",
                    return_value=["session-123.scope: 2 process(es)"],
                ) as mock_orphans:
                    with patch("flux.pam.run_subprocess") as mock_run:
                        helper.user_service_stop()

                        # Should only call stop (no kill)
                        self.assertEqual(mock_run.call_count, 1)
                        call_str = str(mock_run.call_args_list[0])
                        self.assertIn("stop", call_str)

                        # Should NOT check for orphans
                        mock_orphans.assert_not_called()
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_kill_user_slice_orphans_need_sigkill(self):
        """
        Test cleanup when orphans survive SIGTERM but exit after SIGKILL
        """
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                def mock_conf_get(key, default):
                    if key == "pam.kill-user-slice":
                        return True
                    if key == "pam.kill-slice-grace-time":
                        return "0.05s"  # Very short for faster test
                    return default

                helper.handle.conf_get = mock_conf_get

                # Track which phase we're in based on subprocess calls
                kill_count = [0]

                def mock_run_subprocess(args):
                    if "kill" in str(args) and "SIGTERM" in str(args):
                        kill_count[0] = 1  # SIGTERM phase
                    elif "kill" in str(args) and "SIGKILL" in str(args):
                        kill_count[0] = 2  # SIGKILL phase

                def mock_check_orphans():
                    # Before SIGTERM or during SIGTERM wait: orphans exist
                    if kill_count[0] < 2:
                        return ["scope1"]
                    # After SIGKILL: empty
                    else:
                        return []

                with patch.object(
                    helper,
                    "check_orphan_processes",
                    side_effect=lambda: mock_check_orphans(),
                ):
                    with patch("flux.pam.run_subprocess") as mock_run:
                        mock_run.side_effect = mock_run_subprocess
                        helper.user_service_stop()

                        # Should send both SIGTERM and SIGKILL
                        calls = [str(call) for call in mock_run.call_args_list]
                        self.assertTrue(
                            any("SIGTERM" in c for c in calls),
                            "Should send SIGTERM",
                        )
                        self.assertTrue(
                            any("SIGKILL" in c for c in calls),
                            "Should send SIGKILL",
                        )
                        self.assertTrue(
                            any("stop" in c for c in calls),
                            "Should stop service",
                        )
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]

    def test_kill_user_slice_config_true_orphans_remain(self):
        """
        Test user_service_stop with kill=true raises if orphans remain

        When kill=true and orphans remain after SIGKILL + grace time, the
        RuntimeError is still raised but only AFTER systemctl stop is called.
        """
        uid = 12345
        os.environ["FLUX_PAM_LOCK_DIR"] = tempfile.mkdtemp()
        try:
            with patch("flux.Flux") as mock_flux:
                helper = flux.pam.PAMHelper(uid, flux.job.JobID(1))
                helper.handle = mock_flux

                def mock_conf_get(key, default):
                    if key == "pam.kill-user-slice":
                        return True
                    if key == "pam.kill-slice-grace-time":
                        return "0.1s"
                    return default

                helper.handle.conf_get = mock_conf_get

                # Orphans persist through everything
                with patch.object(
                    helper,
                    "check_orphan_processes",
                    return_value=["session-123.scope: 2 process(es)"],
                ):
                    with patch("flux.pam.run_subprocess") as mock_run:
                        # Should raise RuntimeError
                        with self.assertRaises(RuntimeError) as cm:
                            helper.user_service_stop()

                        self.assertIn(
                            "Processes remain in user-12345.slice",
                            str(cm.exception),
                        )
                        self.assertIn(
                            "after SIGKILL",
                            str(cm.exception),
                        )

                        # systemctl stop must be called despite the error
                        mock_run.assert_any_call(
                            [
                                helper.systemctl,
                                "stop",
                                f"user@{uid}.service",
                            ]
                        )
        finally:
            shutil.rmtree(os.environ["FLUX_PAM_LOCK_DIR"], ignore_errors=True)
            del os.environ["FLUX_PAM_LOCK_DIR"]


if __name__ == "__main__":
    if rerun_under_flux(__flux_size()):
        from pycotap import TAPTestRunner

        unittest.main(testRunner=TAPTestRunner())

# vi: ts=4 sw=4 expandtab
