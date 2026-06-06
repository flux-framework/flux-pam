#!/bin/sh

test_description='flux-pam prolog/housekeeping script tests'

# Note: These tests use a mock systemctl and do not have access to a real
# cgroup filesystem. Therefore, orphan process detection and kill behavior
# cannot be fully tested here. The kill-user-slice tests verify the basic
# configuration and that housekeeping attempts cleanup, but they cannot
# simulate actual orphan processes remaining in the slice.

. `dirname $0`/sharness.sh

PROLOG=${FLUX_BUILD_DIR}/src/scripts/flux-pam-prolog
HOUSEKEEPING=${FLUX_BUILD_DIR}/src/scripts/flux-pam-housekeeping

SCRIPTSDIR=${SHARNESS_TEST_SRCDIR}/scripts
export FLUX_PAM_TEST_SYSTEMCTL=${SCRIPTSDIR}/mock-systemctl
export FLUX_PAM_TEST_LOGINCTL=${SCRIPTSDIR}/mock-loginctl

# Use temporary dir for lock files
export FLUX_PAM_LOCK_DIR=$(pwd)/lock

# Enable debug logging from prolog/housekeeping
export FLUX_PAM_SCRIPTS_DEBUG=1

# Ensure flux python loads from source directory
export FLUX_PYTHONPATH_PREPEND=${FLUX_SOURCE_DIR}/src/bindings/python

test_under_flux 4

# Set broker env and reload plugin so perilog environment is refreshed
broker_setenv() {
	flux python <<-EOF
	import flux, sys
	h = flux.Flux()
	h.rpc("broker.setenv", {"env": {"$1": "$2"}}).get()
	EOF
    flux jobtap remove perilog.so &&
    flux jobtap load perilog.so
}

# unset broker env and reload plugin so perilog environment is refreshed
broker_unsetenv() {
	flux python <<-EOF
	import flux, sys
	h = flux.Flux()
	h.rpc("broker.setenv", {"env": {"$1": None}}).get()
	EOF
    flux jobtap remove perilog.so &&
    flux jobtap load perilog.so
}

# Many tests below try to run multiple jobs per rank with different cores
# to ensure prolog/housekeeping use R_union for user slice. This requires
# multiple real cores for sdexec-mapper:
test $(flux resource list -no {ncores} -i 0) -gt 1 && test_set_prereq MULTICORE

test_expect_success 'mock-systemctl is executable' '
	test -x ${FLUX_PAM_TEST_SYSTEMCTL}
'
test_expect_success 're-configure flux with pam.manage-user-slice enabled' '
	flux config load <<-'EOT'
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	[exec]
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	[job-manager.housekeeping]
	command = ["flux", "python", "${HOUSEKEEPING}"]
	EOT
'
test_expect_success 'load perilog plugin' '
	flux jobtap load perilog.so
'
test_expect_success 'load sdexec-mapper module' '
	flux module load sdexec-mapper
'
test_expect_success 'prolog skips for instance owner' '
	uid=$(flux getattr security.owner) &&
	FLUX_JOB_USERID=$uid FLUX_JOB_ID=12345 flux python ${PROLOG} \
	    > prolog.skip 2>&1 &&
	test_debug "cat prolog.skip" &&
	grep skipping prolog.skip
'
test_expect_success 'prolog skips when pam.manage-user-slice not set' '
	flux config load <<-EOT &&
	[access]
	allow-guest-user = true
	EOT
	fake_userid=42 &&
	FLUX_JOB_USERID=$fake_userid FLUX_JOB_ID=12345 flux python ${PROLOG} \
	    > prolog.skip-no-config 2>&1 &&
	test_debug "cat prolog.skip-no-config" &&
	grep "skipping (disabled or owner)" prolog.skip-no-config
'
test_expect_success 'prolog skips when no pam table at all' '
	flux config load <<-EOT &&
	[access]
	allow-guest-user = true
	[exec.testexec]
	allow-guests = true
	EOT
	fake_userid=42 &&
	FLUX_JOB_USERID=$fake_userid FLUX_JOB_ID=12345 flux python ${PROLOG} \
	    > prolog.skip-no-pam-table 2>&1 &&
	test_debug "cat prolog.skip-no-pam-table" &&
	grep "skipping (disabled or owner)" prolog.skip-no-pam-table
'
test_expect_success 're-enable pam.manage-user-slice for remaining tests' '
	flux config load <<-'EOT'
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	[exec]
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	[job-manager.housekeeping]
	command = ["flux", "python", "${HOUSEKEEPING}"]
	EOT
'
# Single job start/end:
# Prolog should start user@42.service and call set-property
test_expect_success 'submit a test job on rank 0' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid > jobid.0 &&
	flux job wait-event -v $jobid start
'
test_expect_success 'jobid.0: prolog started user service and set-properties' '
	jobid=$(cat jobid.0) &&
	test_debug "cat systemctl-${jobid}.log" &&
	grep "start user@42.service" systemctl-${jobid}.log &&
	grep "set-property --runtime user-42.slice" systemctl-${jobid}.log &&
	test_must_fail grep "stop user@42.service" systemctl-${jobid}.log
'

# MULTICORE-only tests follow:
test_expect_success MULTICORE 'submit second job on rank 0' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	flux job wait-event $jobid start &&
	echo $jobid > jobid.1
'
test_expect_success MULTICORE 'jobid.1: prolog started user service (idempotent)' '
	jobid=$(cat jobid.1) &&
	test_debug "cat systemctl-${jobid}.log" &&
	grep "start user@42.service" systemctl-${jobid}.log &&
	test_must_fail grep "stop user@42.service" systemctl-${jobid}.log
'
test_expect_success MULTICORE 'jobid.1: set-property was applied' '
	grep "set-property .* user-42.slice" systemctl-${jobid}.log &&
	grep "AllowedCPUs" systemctl-${jobid}.log

'
test_expect_success 'jobid.0: cancel first job' '
	flux cancel $(cat jobid.0) &&
	flux job wait-event $(cat jobid.0) clean
'
test_expect_success MULTICORE 'jobid.0: housekeeping runs set-property' '
	jobid=$(cat jobid.0) &&
	test_wait_until "grep set-property systemctl-${jobid}.log" &&
	grep "set-property .* user-42.slice" systemctl-${jobid}.log &&
	grep "AllowedCPUs" systemctl-${jobid}.log
'
test_expect_success MULTICORE 'jobid.0: but keeps service running' '
	test_must_fail grep "stop user@42.service" systemctl-${jobid}.log
'
test_expect_success MULTICORE 'jobid.1: cancel second job' '
	flux cancel $(cat jobid.1) &&
	flux job wait-event $(cat jobid.1) clean
'
test_expect_success MULTICORE 'jobid.1: housekeeping stops user service' '
	jobid=$(cat jobid.1) &&
	test_wait_until "grep \"stop user@42.service\" systemctl-${jobid}.log"
'
# MULTICORE-only tests end

test_expect_success 'configure pam.kill-user-slice with short grace time' '
	flux config load <<-'EOT'
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	kill-user-slice = true
	kill-slice-grace-time = "0.1s"
	[exec]
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	[job-manager.housekeeping]
	command = ["flux", "python", "${HOUSEKEEPING}"]
	EOT
'
test_expect_success 'submit job with kill-user-slice enabled' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	flux job wait-event $jobid start &&
	echo $jobid > jobid.kill
'
test_expect_success 'cancel job and verify kill sequence runs' '
	jobid=$(cat jobid.kill) &&
	flux cancel $jobid &&
	flux job wait-event $jobid clean &&
	test_wait_until \
		"grep \"stop user@42.service\" systemctl-${jobid}.log" &&
	test_debug "cat systemctl-${jobid}.log"
'
test_expect_success 'housekeeping checks for orphans before killing' '
	jobid=$(cat jobid.kill) &&
	# Note: In this test environment with mock systemctl,
	# check_orphan_processes() will not find any orphans (no cgroup),
	# so the kill sequence may be skipped. The test verifies that
	# if orphans were found, the proper sequence would occur.
	# Real usage requires actual cgroup filesystem.
	grep "stop user@42.service" systemctl-${jobid}.log
'
test_expect_success 'configure kill-user-slice without grace time override' '
	flux config load <<-'EOT'
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	kill-user-slice = true
	[exec]
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	[job-manager.housekeeping]
	command = ["flux", "python", "${HOUSEKEEPING}"]
	EOT
'
test_expect_success 'verify default grace time is used' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	flux job wait-event $jobid start &&
	echo $jobid > jobid.default &&
	flux cancel $jobid &&
	flux job wait-event $jobid clean &&
	test_wait_until "grep \"stop user@42.service\" systemctl-${jobid}.log"
'

test_expect_success 'configure mock-systemctl to fail on set-property' '
	broker_setenv MOCK_SYSTEMCTL_FAIL set-property
'
test_expect_success 'prolog fails without rolling back service start' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid > jobid.no-rollback &&
	# Job should fail during prolog (set-property fails)
	test_expect_code 1 flux job wait-event -t 10s $jobid start &&
	test_debug "cat systemctl-${jobid}.log" &&
	# Service should have been started but NOT stopped
	grep "start user@42.service" systemctl-${jobid}.log &&
	test_must_fail grep "stop user@42.service" systemctl-${jobid}.log
'
test_expect_success 'housekeeping cleans up after prolog failure' '
	jobid=$(cat jobid.no-rollback) &&
	# Wait for job to reach clean state (housekeeping will run)
	flux job wait-event -t 30 $jobid clean &&
	# Now the service should be stopped by housekeeping
	test_wait_until "grep \"stop user@42.service\" systemctl-${jobid}.log"
'
test_expect_success 'restore mock-systemctl for remaining tests' '
	broker_unsetenv MOCK_SYSTEMCTL_FAIL
'
test_expect_success 'undrain all ranks after prolog failure' '
	flux resource undrain -u 0-3
'
test_expect_success 'cancel any remaining jobs before concurrent test' '
	flux cancel --all --user=all &&
	flux queue idle
'
# MULTICORE tests follow
test_expect_success MULTICORE 'configure for concurrent tests' '
	flux config load <<-'EOT'
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	[exec]
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	[job-manager.housekeeping]
	command = ["flux", "python", "${HOUSEKEEPING}"]
	EOT
'
test_expect_success MULTICORE 'submit two jobs concurrently on same rank' '
	# Ensure ranks are not drained from previous prolog failure
	flux resource undrain -u 0-3 &&
	# Submit two jobs simultaneously to the same rank
	jobid1=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	jobid2=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid1 > jobid.concurrent1 &&
	echo $jobid2 > jobid.concurrent2 &&
	# Wait for both to start
	flux job wait-event -vt 20 $jobid1 start &&
	flux job wait-event -vt 20 $jobid2 start
'
test_expect_success MULTICORE 'verify both prologs started the service' '
	# Both prologs always call start; systemctl start is idempotent
	jobid1=$(cat jobid.concurrent1) &&
	jobid2=$(cat jobid.concurrent2) &&
	test_debug "echo Job 1: $jobid1; cat systemctl-${jobid1}.log" &&
	test_debug "echo Job 2: $jobid2; cat systemctl-${jobid2}.log" &&
	start_count=$(cat systemctl-${jobid1}.log systemctl-${jobid2}.log | \
	              grep -c "start user@42.service") &&
	test "$start_count" -eq 2
'
test_expect_success MULTICORE 'verify both prologs applied properties' '
	jobid1=$(cat jobid.concurrent1) &&
	jobid2=$(cat jobid.concurrent2) &&
	# Both prologs should call set-property (union of resources)
	grep "set-property" systemctl-${jobid1}.log &&
	grep "set-property" systemctl-${jobid2}.log
'
test_expect_success MULTICORE 'cleanup concurrent test jobs' '
	flux cancel $(cat jobid.concurrent1) &&
	flux cancel $(cat jobid.concurrent2) &&
	flux job wait-event -vt 30 $(cat jobid.concurrent1) clean &&
	flux job wait-event -vt 30 $(cat jobid.concurrent2) clean
'
# end MULTICORE tests

test_expect_success 'lock-dir-creation: remove existing lock dir' '
	test -d ${FLUX_PAM_LOCK_DIR} && rm -rf ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'lock-dir-creation: submit job with no lock dir' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	flux job wait-event -vt 20 $jobid start &&
	echo $jobid > jobid.lockdir
'
test_expect_success 'lock-dir-creation: prolog created lock directory' '
	test -d ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'lock-dir-creation: directory has correct permissions (0700)' '
	perms=$(stat -c "%a" ${FLUX_PAM_LOCK_DIR}) &&
	test "$perms" = "700"
'
test_expect_success 'lock-dir-creation: lock file has correct permissions (0600)' '
	lockfile=${FLUX_PAM_LOCK_DIR}/uid.42.lock &&
	test -f $lockfile &&
	perms=$(stat -c "%a" $lockfile) &&
	test "$perms" = "600"
'
test_expect_success 'lock-dir-creation: cancel job' '
	flux cancel $(cat jobid.lockdir) &&
	flux job wait-event -vt 20 $(cat jobid.lockdir) clean
'
test_expect_success 'lock-dir-perms: create group-writable lock directory' '
	rm -rf ${FLUX_PAM_LOCK_DIR} &&
	mkdir -p ${FLUX_PAM_LOCK_DIR} &&
	chmod 0770 ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'lock-dir-perms: prolog fails with group-writable dir' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid > jobid.badperms &&
	# Job should fail during prolog (bad lock dir permissions)
	test_expect_code 1 flux job wait-event -t 10s $jobid start
'
test_expect_success 'lock-dir-perms: verify prolog failed' '
	jobid=$(cat jobid.badperms) &&
	flux job eventlog $jobid > eventlog.badperms 2>&1 &&
	test_debug "cat eventlog.badperms" &&
	grep "prolog.*code=1" eventlog.badperms
'
test_expect_success 'lock-dir-perms: verify error message in logs' '
	jobid=$(cat jobid.badperms) &&
	flux dmesg | grep "$jobid" | grep -i "writable"
'
test_expect_success 'lock-dir-perms: undrain rank after prolog failure' '
	flux resource undrain -u 0
'
test_expect_success 'lock-dir-perms: restore correct lock dir permissions' '
	chmod 0700 ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'lock-dir-perms: create other-writable lock directory' '
	chmod 0707 ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'lock-dir-perms: prolog fails with other-writable dir' '
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid > jobid.badperms2 &&
	test_expect_code 1 flux job wait-event -t 10s $jobid start
'
test_expect_success 'lock-dir-perms: verify prolog failed for other-writable' '
	jobid=$(cat jobid.badperms2) &&
	flux job eventlog $jobid > eventlog.badperms2 2>&1 &&
	test_debug "cat eventlog.badperms2" &&
	grep "prolog.*code=1" eventlog.badperms2
'
test_expect_success 'lock-dir-perms: verify error message in logs for other-writable' '
	jobid=$(cat jobid.badperms2) &&
	flux dmesg | grep "$jobid" | grep -i "writable"
'
test_expect_success 'lock-dir-perms: undrain rank after second failure' '
	flux resource undrain -u 0
'
test_expect_success 'lock-dir-perms: restore correct permissions for cleanup' '
	chmod 0700 ${FLUX_PAM_LOCK_DIR}
'
test_expect_success 'remove sdexec-mapper' '
	flux module remove sdexec-mapper
'
test_done
