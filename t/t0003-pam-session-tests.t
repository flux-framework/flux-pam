#!/bin/sh

test_description='flux-pam PAM session verification tests'

# Append --logfile option if FLUX_TESTS_LOGFILE is set in environment:
test -n "$FLUX_TESTS_LOGFILE" && set -- "$@" --logfile

. `dirname $0`/sharness.sh

PAM_FLUX_PATH=${FLUX_BUILD_DIR}/src/pam/.libs/pam_flux.so
PAMTEST=${FLUX_BUILD_DIR}/t/pamtest

if ! test -x ${PAMTEST}; then
	echo >&2 "pamtest test program not found at ${PAMTEST}"
	echo >&2 "Do you need to run 'make check'?"
	exit 1
fi

# This test requires FLUX_PAM_TEST_USER to be set since it starts/stops
# and modifies the test user manager and slice. This makes the test opt-in
# only to avoid inadvertently running in production.
if ! test -n "${FLUX_PAM_TEST_USER}" || ! id -u "${FLUX_PAM_TEST_USER}"; then
	skip_all="skipping because FLUX_PAM_TEST_USER not set"
	test_done
fi

#  Check for libpam_wrapper.so
LD_PRELOAD=libpam_wrapper.so ${PAMTEST} -h >ld_preload.out 2>&1
if grep -i error ld_preload.out >/dev/null 2>&1; then
	skip_all='libpam_wrapper.so not found. Skipping all tests'
	test_done
fi

# Check for systemd
if ! test_have_prereq HAVE_SYSTEMD; then
	skip_all='systemd not available'
	test_done
fi

# Check for sudo support
if ! test_have_prereq SUDO; then
	skip_all='skipping slice state tests, sudo support not found'
	test_done
fi

# Check if we have systemd support built in
if ! ldd ${FLUX_BUILD_DIR}/src/pam/.libs/pam_flux.so | grep -q libsystemd; then
	skip_all='pam_flux.so not built with libsystemd support'
	test_done
fi

# This test needs a flux instance
test_under_flux 1

# Configure flux instance with pam.manage-user-slice enabled
# guest and root-owner access, and guest allowed to use testexec service
flux config load <<-'EOF'
[access]
allow-guest-user = true
allow-root-owner = true
[pam]
manage-user-slice = true
[exec.testexec]
allow-guests = true
EOF

TEST_USER=${FLUX_PAM_TEST_USER}
if ! getent passwd ${TEST_USER} >/dev/null 2>&1; then
	skip_all="user ${TEST_USER} does not exist"
	test_done
fi

TEST_UID=$(id -u ${TEST_USER})

# FAKE_USERID required for submit_as_guest()
FAKE_USERID=${TEST_UID}

# Use test trash directory for lock files (matches PAM stack lock-dir)
export FLUX_PAM_LOCK_DIR=$(pwd)

# Acquire lock for this user's systemd service
test_systemd_user_lock ${TEST_UID}

pamtest_session() {
	sudo FLUX_URI=${FLUX_URI} \
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_DEBUGLEVEL=2 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	${PAMTEST} -v -S -s pam-session-test "$@"
}

reset_test_scopes() {
	for scope in \
	    $(systemctl list-units --plain --no-legend --no-pager \
	      "flux-pam-test*"); do
		sudo systemctl stop $scope 2>/dev/null || true
		sudo systemctl reset-failed $scope 2>/dev/null || true
	done
}

# Notes on the test PAM stack:
# - An auth line is required: use of pam_localuser.so means test users must
#   exist in the local passwd file.
# - We use pam_succeed_if.so to test the case where a similar PAM module
#   bypasses the pam_flux.so check for local jobs, thus pam_flux_authorized
#   is not set.
# - pam_flux.so is in the session stack as 'requisite' so it fails on any
#   session setup error, but is ignored if it returns PAM_IGNORE.
# - Fall through to pam_unix.so is required or else PAM_IGNORE causes overall
#   pamtest failure.
#
test_expect_success 'create PAM stack' '
	cat <<-EOF >pam-session-test
	auth    required   pam_localuser.so
	account sufficient pam_succeed_if.so uid < 500
	account sufficient ${PAM_FLUX_PATH}
	session requisite  ${PAM_FLUX_PATH} debug scope-prefix=flux-pam-test lock-dir=$(pwd)
	session required   pam_unix.so
	EOF
'
test_expect_success 'session is skipped if pam_flux.so did not authorize user' '
	pamtest_session -u root >skipped.out 2>&1 &&
	test_debug "cat skipped.out" &&
	grep "skipping session setup" skipped.out
'
test_expect_success 'get service state for test user' '
	SERVICE_STATE=$(systemctl is-active user@${TEST_UID}.service || :) &&
	test_debug "echo user@${TEST_UID} is ${SERVICE_STATE}"
'
test_expect_success 'slice-state: stop any existing service for test user' '
	sudo systemctl stop user@${TEST_UID}.service || :
'
test_expect_success 'slice-state: remove any existing marker' '
	sudo rm -f ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'slice-state: clean up any scopes from previous tests' '
	reset_test_scopes
'
test_expect_success 'slice-state: submit test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event -vt 20 $jobid start
'
test_expect_success 'slice-state: manually create marker (prolog not configured)' '
	sudo touch ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active &&
	test -f ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'slice-state: session attach succeeds with marker present' '
	pamtest_session -u ${TEST_USER}
'
test_expect_success 'slice-state: remove marker to simulate teardown' '
	sudo rm -f ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'slice-state: session attach fails without marker' '
	test_must_fail pamtest_session -u ${TEST_USER}
'
test_expect_success 'slice-state: cancel running job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'scope-create: create marker for test' '
	sudo mkdir -p ${FLUX_PAM_LOCK_DIR} &&
	sudo touch ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'scope-create: clean up any scopes from previous tests' '
	reset_test_scopes
'
test_expect_success 'scope-create: submit test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event $jobid start
'
test_expect_success 'scope-create: session attach creates scope under user slice' '
	pamtest_session -u ${TEST_USER} -- \
		sh -c "systemctl show flux-pam-test-\$PPID.scope \
		       -p Slice --value | grep user-${TEST_UID}.slice" \
		>pamtest.out 2>&1 &&
	test_debug "cat pamtest.out" &&
	grep "attached user ${TEST_USER}.*scope=flux-pam-test" pamtest.out
'
test_expect_success 'scope-create: cancel test job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'session-env: submit test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event $jobid start
'
test_expect_success 'session-env: session attach sets XDG_RUNTIME_DIR' '
	pamtest_session -u ${TEST_USER} -e >pamtest_env.out 2>&1 &&
	grep "XDG_RUNTIME_DIR=/run/user/${TEST_UID}" pamtest_env.out
'
test_expect_success 'session-env: session attach sets DBUS_SESSION_BUS_ADDRESS' '
	grep "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TEST_UID}/bus" \
		pamtest_env.out
'
test_expect_success 'session-env: cancel test job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'lock-dir-perms: create group-writable lock directory' '
	mkdir -p bad-lock-dir &&
	chmod 0770 bad-lock-dir
'
test_expect_success 'lock-dir-perms: create PAM stack with bad lock-dir' '
	cat <<-EOF >pam-session-badlock
	auth    required   pam_localuser.so
	account sufficient pam_succeed_if.so uid < 500
	account sufficient ${PAM_FLUX_PATH}
	session requisite  ${PAM_FLUX_PATH} debug scope-prefix=flux-pam-test lock-dir=$(pwd)/bad-lock-dir
	session required   pam_unix.so
	EOF
'
test_expect_success 'lock-dir-perms: submit test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event $jobid start
'
test_expect_success 'lock-dir-perms: create marker' '
	sudo touch ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'lock-dir-perms: session fails with group-writable dir' '
	test_must_fail \
		sudo FLUX_URI=${FLUX_URI} \
		LD_PRELOAD=libpam_wrapper.so \
		PAM_WRAPPER=1 \
		PAM_WRAPPER_DEBUGLEVEL=2 \
		PAM_WRAPPER_SERVICE_DIR=$(pwd) \
		${PAMTEST} -v -S -s pam-session-badlock -u ${TEST_USER} \
		>badlock.out 2>&1 &&
	test_debug "cat badlock.out" &&
	grep "group/other writable" badlock.out
'
test_expect_success 'lock-dir-perms: cancel test job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'lock-dir-perms: cleanup group-writable directory' '
	sudo rm -rf bad-lock-dir
'
test_expect_success 'lock-dir-perms: create other-writable lock directory' '
	mkdir -p bad-lock-dir2 &&
	chmod 0707 bad-lock-dir2
'
test_expect_success 'lock-dir-perms: update PAM stack with other-writable dir' '
	cat <<-EOF >pam-session-badlock2
	auth    required   pam_localuser.so
	account sufficient pam_succeed_if.so uid < 500
	account sufficient ${PAM_FLUX_PATH}
	session requisite  ${PAM_FLUX_PATH} debug scope-prefix=flux-pam-test lock-dir=$(pwd)/bad-lock-dir2
	session required   pam_unix.so
	EOF
'
test_expect_success 'lock-dir-perms: submit another test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event $jobid start
'
test_expect_success 'lock-dir-perms: recreate marker' '
	sudo touch ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_expect_success 'lock-dir-perms: session fails with other-writable dir' '
	test_must_fail \
		sudo FLUX_URI=${FLUX_URI} \
		LD_PRELOAD=libpam_wrapper.so \
		PAM_WRAPPER=1 \
		PAM_WRAPPER_DEBUGLEVEL=2 \
		PAM_WRAPPER_SERVICE_DIR=$(pwd) \
		${PAMTEST} -v -S -s pam-session-badlock2 -u ${TEST_USER} \
		>badlock2.out 2>&1 &&
	test_debug "cat badlock2.out" &&
	grep "group/other writable" badlock2.out
'
test_expect_success 'lock-dir-perms: cancel last test job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'lock-dir-perms: cleanup other-writable directory' '
	sudo rm -rf bad-lock-dir2
'
test_expect_success 'systemd-user: create PAM stack' '
	cat <<-EOF >systemd-user
	auth    required   pam_localuser.so
	account sufficient pam_succeed_if.so uid < 500
	account sufficient ${PAM_FLUX_PATH}
	account required   pam_permit.so
	session requisite  ${PAM_FLUX_PATH} debug
	session required   pam_unix.so
	EOF
'
test_expect_success 'systemd-user: submit test job' '
	jobid=$(submit_as_guest 5m sleep 300) &&
	flux job wait-event $jobid start
'
test_expect_success 'systemd-user: session skips systemd-user service' '
	sudo FLUX_URI=${FLUX_URI} \
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_DEBUGLEVEL=2 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	${PAMTEST} -v -S -s systemd-user -u ${TEST_USER} \
		>systemd-user.out 2>&1 &&
	test_debug "cat systemd-user.out" &&
	grep "skipping for systemd-user service" systemd-user.out
'
test_expect_success 'systemd-user: cancel test job' '
	flux cancel $jobid &&
	flux job wait-event -vt 20 $jobid clean
'
test_expect_success 'cleanup test scopes' '
	reset_test_scopes
'
test_expect_success 'reset state of test user manager and marker' '
	if test "${SERVICE_STATE}" = "inactive"; then
		sudo systemctl stop user@${TEST_UID}.service
	fi &&
	sudo rm -f ${FLUX_PAM_LOCK_DIR}/uid.${TEST_UID}.active
'
test_done
