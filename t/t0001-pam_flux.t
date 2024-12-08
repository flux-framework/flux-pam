#!/bin/sh

test_description='Basic plugin tests'

. `dirname $0`/sharness.sh

export FLUX_URI_RESOLVE_LOCAL=t
PAM_FLUX_PATH=${FLUX_BUILD_DIR}/src/pam/.libs/pam_flux.so
PAMTEST=${FLUX_BUILD_DIR}/t/pamtest

if ! test -x ${PAMTEST}; then
	echo >&2 "pamtest test program not found at ${PAMTEST}"
	echo >&2 "Do you need to run 'make check'?"
	exit 1
fi

mkdir config
test_under_flux 2 full -o,--config-path=$(pwd)/config

#  Check for libpam_wrapper.so
LD_PRELOAD=libpam_wrapper.so ${PAMTEST} -h >ld_preload.out 2>&1
if grep -i error ld_preload.out >/dev/null 2>&1; then
	skip_all='libpam_wrapper.so not found. Skipping all tests'
	test_done
fi

pamtest() {
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	${PAMTEST} -v -s pam-test "$@"
}

pamtest_on_rank() {
	RANK=$1
	shift
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	flux exec -r ${RANK} ${PAMTEST} -v -s pam-test "$@"
}

test_expect_success 'pam_flux: create pam-test PAM stack' '
	cat <<-EOF >pam-test
	auth    required   pam_localuser.so

	account required ${PAM_FLUX_PATH}
	EOF
'
test_expect_success 'pam_flux: module denies access with no jobs running' '
	test_must_fail pamtest -u ${USER} 
'
test_expect_success 'pam_flux: module allows access with a job running' '
	jobid=$(flux submit --wait-event=alloc sleep 300) &&
	pamtest -u ${USER}
'
test_expect_success 'pam_flux: module does not let any old user in' '
	test_must_fail pamtest -u nobody
'
test_expect_success 'pam_flux: module denies access after job terminates' '
	flux job cancel $jobid &&
	flux job wait-event -vt 15 $jobid free &&
	test_must_fail pamtest -u ${USER}
'
test_expect_success 'pam_flux: module denies access on flux_open() failure' '
	( export FLUX_URI=/tmp/foo &&
	  test_must_fail pamtest -u ${USER} )
'
test_expect_success 'pam_flux: module denies access during CLEANUP' '
	cat <<-EOF >config/epilog.toml &&
	[job-manager.epilog]
	command = [ "flux", "event", "sub", "-c1",  "pam-test-done" ]
	EOF
	flux config reload &&
	test_when_finished "rm config/epilog.toml && flux config reload" &&
	flux jobtap load perilog.so &&
	jobid=$(flux submit --wait-event=epilog-start hostname) &&
	test_must_fail pamtest -u ${USER} &&
	flux jobs -o "{id.f58}: {state}" &&
	flux event pub pam-test-done &&
	flux job wait-event -vt 15 ${jobid} clean
'
test_expect_success 'add allow-guest-user to pam_flux module options' '
	cat <<-EOF >pam-test
	auth    required   pam_localuser.so
	account required ${PAM_FLUX_PATH} allow-guest-user
	EOF
'
test_expect_success 'pam_flux: module denies access with allow-guest-access' '
	test_must_fail pamtest -u ${USER} 2>allow-guest.err &&
	test_debug "cat allow-guest.err" &&
	grep "Access denied: user ${USER}" allow-guest.err &&
	test_must_fail pamtest -u nobody 2>allow-guest1.err &&
	test_debug "cat allow-guest1.err" &&
	grep "Access denied: user nobody" allow-guest1.err
'
test_expect_success 'pam_flux: access denied if job not an instance' '
	id=$(flux submit -N1 --requires=rank:0 sleep inf) &&
	test_must_fail pamtest -u nobody 2>no-uri.err &&
	test_debug "cat no-uri.err" &&
	grep "Access denied: user nobody" no-uri.err &&
	flux cancel $id &&
	flux job wait-event -vt 15 $id clean
'
test_expect_success 'pam_flux: but job user still given access' '
	id=$(flux submit -N1 --requires=rank:0 sleep inf) &&
	pamtest -u ${USER} && # but job user is still allowed
	flux cancel $id &&
	flux job wait-event -vt 15 $id clean
'
test_expect_success 'pam_flux: access denied if access.allow-guest-user=0' '
	id=$(flux alloc --bg -N1 --requires=rank:0) &&
	test_must_fail pamtest -u nobody 2>allow-guest2.err &&
	test_debug "cat allow-guest2.err" &&
	grep "Access denied: user nobody" allow-guest2.err &&
	flux cancel $id &&
	flux job wait-event -vt 15 $id clean
'
test_expect_success 'pam_flux: access allowed if access.allow-guest-user=1' '
	id=$(flux alloc --requires=rank:0 \
             --conf=access.allow-guest-user=true --bg -N1) &&
	pamtest -u nobody &&
	flux cancel $id &&
	flux job wait-event -vt 15 $id clean
'
test_expect_success 'pam_flux: access denied if not rank 0 of job' '
	id=$(flux alloc --conf=access.allow-guest-user=true --bg -N2) &&
	test_must_fail pamtest_on_rank 1 -u nobody 2>allow-guest3.err &&
	test_debug "cat allow-guest3.err" &&
	grep "Access denied: user nobody" allow-guest3.err &&
	flux cancel $id &&
	flux job wait-event -vt 15 $id clean
'
test_done
