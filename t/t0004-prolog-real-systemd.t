#!/bin/sh

test_description='flux-pam prolog tests against a real systemd manager

The t0002 tests use a mock systemctl, so a property value that systemd
would reject still passes. These tests run the prolog against the user
systemd manager, which parses and validates properties exactly as the
system manager does.

Properties are applied to user-$UID.slice in the user manager, which is a
distinct unit from the system-scope slice of the same name and needs no
privilege. Devices come from a mapper returning nodes present on every
system, so the DeviceAllow path is covered without GPUs.

This covers ingest only, not enforcement. The device controller is not
delegated to the user manager, which therefore stores DeviceAllow and
reports it back without acting on it. What is under test is that flux
emits properties systemd accepts; whether the resulting cgroup denies a
device requires the system manager and root, and is out of scope here.
'

. `dirname $0`/sharness.sh

if ! systemctl --user show --property Version >/dev/null 2>&1; then
	skip_all="user systemd is not running"
	test_done
fi
if ! busctl --user status >/dev/null 2>&1; then
	skip_all="user dbus is not running"
	test_done
fi

PROLOG=${FLUX_BUILD_DIR}/src/scripts/flux-pam-prolog

SCRIPTSDIR=${SHARNESS_TEST_SRCDIR}/scripts
export FLUX_PAM_TEST_SYSTEMCTL=${SCRIPTSDIR}/user-systemctl
export FLUX_PAM_TEST_LOGINCTL=${SCRIPTSDIR}/mock-loginctl

export FLUX_PAM_LOCK_DIR=$(pwd)/lock
export FLUX_PAM_SCRIPTS_DEBUG=1

export FLUX_PYTHONPATH_PREPEND=${FLUX_SOURCE_DIR}/src/bindings/python

# The guest uid the prolog manages. Its slice is only ever touched in the
# user manager, so it needs no corresponding account.
TEST_SLICE_UID=42
SLICE=user-${TEST_SLICE_UID}.slice

test_under_flux 1

# Concurrent runs share one systemd user manager, so they would contend for
# ${SLICE} in it. Serialize on the real uid, which identifies that manager.
# Called after test_under_flux so the lock is not lost on re-exec.
test_systemd_user_lock $(id -u)

# Drop any drop-ins this test created. The properties must outlive the test
# that applies them, so this runs as a final test rather than per-test
# cleanup; sharness runs it even if an earlier assertion fails.
slice_revert() {
	systemctl --user revert ${SLICE} >/dev/null 2>&1 || :
}

test_expect_success 'user-systemctl wrapper is executable' '
	test -x ${FLUX_PAM_TEST_SYSTEMCTL}
'
test_expect_success 'user systemd rejects a comma-joined DeviceAllow' '
	test_must_fail ${FLUX_PAM_TEST_SYSTEMCTL} set-property --runtime \
	    ${SLICE} "DeviceAllow=/dev/null rw,/dev/zero rw" 2>comma.err &&
	test_debug "cat comma.err" &&
	grep -i "rwm flags" comma.err
'
test_expect_success 'configure flux with the test device mapper' '
	flux config load <<-EOT &&
	[access]
	allow-guest-user = true
	[pam]
	manage-user-slice = true
	[exec]
	service = "sdexec"
	sdexec-constrain-resources = true
	[exec.testexec]
	allow-guests = true
	[sdexec]
	mapper = "test_device_mapper.TestDeviceMapper"
	mapper-searchpath = "${SCRIPTSDIR}"
	[job-manager.prolog]
	per-rank = true
	command = ["flux", "python", "${PROLOG}"]
	EOT
	flux jobtap load perilog.so
'
test_expect_success 'load sdexec-mapper module' '
	flux module load sdexec-mapper
'
test_expect_success 'mapper returns a comma-joined DeviceAllow' '
	test "$(flux module stats sdexec-mapper | jq -r .config.mapper_class)" \
	    = "test_device_mapper.TestDeviceMapper"
'
test_expect_success 'prolog applies constraints to a real slice' '
	slice_revert &&
	jobid=$(submit_as_guest 5m --requires="rank:0" sleep 300) &&
	echo $jobid >jobid.0 &&
	flux job wait-event -v $jobid start
'
# systemd parsed and stored these, which is what is being checked. It does
# not enforce them here; see the note in the description above.
test_expect_success 'slice has one DeviceAllow entry per device' '
	systemctl --user show ${SLICE} -p DeviceAllow >devices.out &&
	test_debug "cat devices.out" &&
	grep -x "DeviceAllow=/dev/null rw" devices.out &&
	grep -x "DeviceAllow=/dev/zero rw" devices.out &&
	grep -x "DeviceAllow=char-pts rw" devices.out
'
test_expect_success 'no DeviceAllow entry retains an embedded comma' '
	test_must_fail grep "DeviceAllow=.*,.*" devices.out
'
test_expect_success 'slice has the remaining constraint properties' '
	systemctl --user show ${SLICE} \
	    -p DevicePolicy -p AllowedCPUs -p AllowedMemoryNodes >props.out &&
	test_debug "cat props.out" &&
	grep -x "DevicePolicy=closed" props.out &&
	grep "^AllowedCPUs=." props.out
'
test_expect_success 'prolog published the active marker' '
	test -f ${FLUX_PAM_LOCK_DIR}/uid.${TEST_SLICE_UID}.active
'
test_expect_success 'cancel job' '
	flux cancel $(cat jobid.0) &&
	flux job wait-event $(cat jobid.0) clean
'
test_expect_success 'remove sdexec-mapper' '
	flux module remove sdexec-mapper
'
test_expect_success 'revert slice drop-ins' '
	slice_revert &&
	systemctl --user show ${SLICE} -p DeviceAllow >reverted.out &&
	test_debug "cat reverted.out" &&
	test_must_fail grep "DeviceAllow=." reverted.out
'
test_done
