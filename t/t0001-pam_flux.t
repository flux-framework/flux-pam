#!/bin/sh

test_description='Basic plugin tests'

. `dirname $0`/sharness.sh

PAM_FLUX_PATH=${FLUX_BUILD_DIR}/src/pam/.libs/pam_flux.so
PAMTEST=${FLUX_BUILD_DIR}/t/pamtest

if ! test -x ${PAMTEST}; then
	echo >&2 "pamtest test program not found at ${PAMTEST}"
	echo >&2 "Do you need to run 'make check'?"
	exit 1
fi

mkdir config
test_under_flux 1 full -o,--config-path=$(pwd)/config

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
	jobid=$(flux mini submit --wait-event=alloc sleep 300) &&
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
	#  Note: prolog only needs to be configured due to bug in
	#   flux-core <= v0.40.0
	[job-manager.prolog]
	command = [ "/bin/true" ]

	[job-manager.epilog]
	command = [ "flux", "event", "sub", "-c1",  "pam-test-done" ]

	EOF
	flux config reload &&
	flux jobtap load perilog.so &&
	jobid=$(flux mini submit --wait-event=epilog-start hostname) &&
	test_must_fail pamtest -u ${USER} &&
	flux jobs -o "{id.f58}: {state}" &&
	flux event pub pam-test-done &&
	flux job wait-event -vt 15 ${jobid} clean
'
test_done
