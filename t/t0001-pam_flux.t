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
#  Allow root to connect, as for a system instance, so pamtest can run
#  as root.
cat >config/access.toml <<EOF
[access]
allow-root-owner = true
EOF
test_under_flux 2 full -o,--config-path=$(pwd)/config

#  Check for libpam_wrapper.so
LD_PRELOAD=libpam_wrapper.so ${PAMTEST} -h >ld_preload.out 2>&1
if grep -i error ld_preload.out >/dev/null 2>&1; then
	skip_all='libpam_wrapper.so not found. Skipping all tests'
	test_done
fi

pamtest_service() {
	service=$1
	shift
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	${PAMTEST} -v -s ${service} "$@"
}

#  Write PAM stack FILE with a pam_flux account line using module ARGS.
write_account_stack() {
	file=$1
	shift
	cat <<-EOF >$file
	auth    required   pam_localuser.so
	account required ${PAM_FLUX_PATH} $*
	EOF
}

pamtest() {
	pamtest_service pam-test "$@"
}

#  Run pamtest on RANK with a copy of the pam-test stack that points
#  pam_flux at the local URI of that rank.
pamtest_on_rank() {
	RANK=$1
	shift
	uri=$(flux exec -r ${RANK} flux getattr local-uri) &&
	sed "s|uri=${FLUX_URI}|uri=${uri}|" pam-test >pam-test-rank${RANK} &&
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	flux exec -r ${RANK} ${PAMTEST} -v -s pam-test-rank${RANK} "$@"
}

test_expect_success 'pam_flux: create pam-test PAM stack' '
	write_account_stack pam-test uri=${FLUX_URI}
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
	flux cancel $jobid &&
	flux job wait-event -vt 15 $jobid free &&
	test_must_fail pamtest -u ${USER}
'
test_expect_success 'pam_flux: module denies access on flux_open() failure' '
	write_account_stack pam-test-nouri uri=local:///nonexistent/local &&
	(export PAM_WRAPPER_DEBUGLEVEL=2 &&
	 test_must_fail pamtest_service pam-test-nouri -u ${USER} \
		>nouri.out 2>&1) &&
	test_debug "cat nouri.out" &&
	grep "Unable to connect to Flux at local:///nonexistent/local" nouri.out
'
#  Without uri=, pam_flux connects to the system instance, not FLUX_URI.
#  The test user has no job there, so access is denied either way, and
#  if no system instance runs here, the error names the system instance.
test_expect_success 'pam_flux: module ignores FLUX_URI in the environment' '
	write_account_stack pam-test-default &&
	(export FLUX_URI=local:///nonexistent/local &&
	 export PAM_WRAPPER_DEBUGLEVEL=2 &&
	 test_must_fail pamtest_service pam-test-default -u ${USER} \
		>default-uri.out 2>&1) &&
	test_debug "cat default-uri.out" &&
	grep "Access denied: user ${USER}" default-uri.out &&
	test_must_fail grep nonexistent default-uri.out &&
	if grep "Unable to connect" default-uri.out; then
		grep "Unable to connect to Flux at the system instance" \
			default-uri.out
	fi
'
#  $1 is the whole module argument, so a URI with whitespace can use
#  PAM bracket syntax, e.g. "[uri=local:///run/.. ]".
test_pam_flux_bad_uri() {
	write_account_stack pam-test-baduri "$1" &&
	(export PAM_WRAPPER_DEBUGLEVEL=2 &&
	 test_must_fail pamtest_service pam-test-baduri -u ${USER} \
		>bad-uri.out 2>&1) &&
	test_debug "cat bad-uri.out" &&
	grep "must be local:// with an absolute path" bad-uri.out
}
test_expect_success 'pam_flux: module rejects a uri that is not local://' '
	test_pam_flux_bad_uri uri=ssh://localhost/tmp/local
'
test_expect_success 'pam_flux: module rejects a relative local:// uri' '
	test_pam_flux_bad_uri uri=local://run/flux/local
'
test_expect_success 'pam_flux: module rejects a local:// uri with ..' '
	test_pam_flux_bad_uri uri=local:///run/../tmp/local &&
	test_pam_flux_bad_uri uri=local:///run/flux/..
'
test_expect_success 'pam_flux: module rejects a local:// uri with whitespace' '
	test_pam_flux_bad_uri "[uri=local:///run/.. ]" &&
	test_pam_flux_bad_uri "[uri=local:///run/flux local]"
'
test_expect_success 'pam_flux: module denies silently with PAM_SILENT' '
	(export PAM_WRAPPER_DEBUGLEVEL=2 &&
	 test_must_fail pamtest -q -u ${USER} >silent.out 2>&1) &&
	test_debug "cat silent.out" &&
	grep "access denied for user ${USER}" silent.out &&
	test_must_fail grep "Access denied: user ${USER}" silent.out
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
#  pam_flux runs as root in programs such as su. Check that the module can
#  connect and deny there. sudo resets the environment, so pass the
#  PAM wrapper settings explicitly.
test_expect_success SUDO 'pam_flux: module denies user with no job when run as root' '
	test_must_fail sudo env \
		LD_PRELOAD=libpam_wrapper.so \
		PAM_WRAPPER=1 \
		PAM_WRAPPER_DEBUGLEVEL=2 \
		PAM_WRAPPER_SERVICE_DIR=$(pwd) \
		${PAMTEST} -v -s pam-test -u ${USER} >root-nojob.out 2>&1 &&
	test_debug "cat root-nojob.out" &&
	test_must_fail grep "Unable to connect" root-nojob.out &&
	grep "Access denied: user ${USER}" root-nojob.out
'
#  FLUX_LOCAL_CONNECTOR_RETRY_COUNT=bogus makes flux_open() of a local://
#  URI fail, and FLUX_HANDLE_TRACE=1 traces messages to stderr, so a job
#  user is admitted without a trace only if pam_flux removed them. The
#  duplicate entry added with -D follows the first, which getenv() returns,
#  so the first must be the one restored. Export in a subshell, since in
#  some shells an assignment before a function call persists after it.
test_expect_success 'pam_flux: module ignores FLUX_* environment variables' '
	jobid=$(flux submit --wait-event=alloc sleep 300) &&
	test_when_finished "flux cancel $jobid" &&
	(export FLUX_URI=local:///nonexistent/local &&
	 export FLUX_LOCAL_CONNECTOR_RETRY_COUNT=bogus &&
	 export FLUX_HANDLE_TRACE=1 &&
	 export PAM_WRAPPER_DEBUGLEVEL=2 &&
	 pamtest -u ${USER} \
		-E FLUX_URI -E FLUX_LOCAL_CONNECTOR_RETRY_COUNT \
		-D FLUX_LOCAL_CONNECTOR_RETRY_COUNT=second \
		>flux-env.out 2>&1) &&
	test_debug "cat flux-env.out" &&
	grep "pam_acct_mgmt rc=0" flux-env.out &&
	test_must_fail grep "job-list.list" flux-env.out
'
test_expect_success 'pam_flux: module restores FLUX_* environment variables' '
	grep "^FLUX_URI=local:///nonexistent/local$" flux-env.out &&
	grep "^FLUX_LOCAL_CONNECTOR_RETRY_COUNT=bogus$" flux-env.out
'
test_expect_success 'add allow-guest-user to pam_flux module options' '
	write_account_stack pam-test uri=${FLUX_URI} allow-guest-user
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
#  The account module never denies for systemd-user: it admits users with
#  an active job or active marker, and otherwise returns PAM_IGNORE so the
#  rest of the stack decides. Run with debug and PAM_WRAPPER_DEBUGLEVEL=2 so
#  the module's syslog messages show which path was taken.
pamtest_systemd_user() {
	LD_PRELOAD=libpam_wrapper.so \
	PAM_WRAPPER=1 \
	PAM_WRAPPER_DEBUGLEVEL=2 \
	PAM_WRAPPER_SERVICE_DIR=$(pwd) \
	${PAMTEST} -v -s systemd-user "$@"
}

#  Run pamtest for systemd-user while holding the user lock, as the prolog
#  does while it starts user@UID.service.
pamtest_systemd_user_locked() {
	flock ${LOCK_DIR}/uid.${MY_UID}.lock \
		env LD_PRELOAD=libpam_wrapper.so \
		PAM_WRAPPER=1 \
		PAM_WRAPPER_DEBUGLEVEL=2 \
		PAM_WRAPPER_SERVICE_DIR=$(pwd) \
		${PAMTEST} -v -s systemd-user "$@"
}

if command -v flock >/dev/null; then
	test_set_prereq FLOCK
fi

MY_UID=$(id -u)
LOCK_DIR=$(pwd)/systemd-user-lock

test_expect_success 'pam_flux: create systemd-user lock dir' '
	mkdir -m 0700 ${LOCK_DIR}
'
test_expect_success 'pam_flux: create systemd-user stack with pam_permit' '
	cat <<-EOF >systemd-user
	auth    required   pam_localuser.so
	account required   pam_permit.so
	account required   ${PAM_FLUX_PATH} uri=${FLUX_URI} debug lock-dir=${LOCK_DIR}
	EOF
'
test_expect_success 'pam_flux: systemd-user ignores user with no job' '
	pamtest_systemd_user -u ${USER} >su-nojob.out 2>&1 &&
	test_debug "cat su-nojob.out" &&
	grep "no active job for uid=${MY_UID}, ignoring" su-nojob.out &&
	test_must_fail grep "Access denied" su-nojob.out
'
test_expect_success 'pam_flux: systemd-user ignores user if Flux is unreachable' '
	cat <<-EOF >systemd-user &&
	auth    required   pam_localuser.so
	account required   pam_permit.so
	account required   ${PAM_FLUX_PATH} uri=local:///nonexistent/local debug lock-dir=${LOCK_DIR}
	EOF
	pamtest_systemd_user -u ${USER} >su-nouri.out 2>&1 &&
	test_debug "cat su-nouri.out" &&
	grep "no active job for uid=${MY_UID}, ignoring" su-nouri.out
'
test_expect_success 'pam_flux: create systemd-user stack ending in pam_deny' '
	cat <<-EOF >systemd-user
	auth    required   pam_localuser.so
	account sufficient ${PAM_FLUX_PATH} uri=${FLUX_URI} debug lock-dir=${LOCK_DIR}
	account required   pam_deny.so
	EOF
'
test_expect_success 'pam_flux: systemd-user with pam_deny denies user with no job' '
	test_must_fail pamtest_systemd_user -u ${USER} >su-deny.out 2>&1 &&
	test_debug "cat su-deny.out" &&
	grep "no active job for uid=${MY_UID}, ignoring" su-deny.out
'
test_expect_success 'pam_flux: systemd-user with pam_deny admits user with a job' '
	jobid=$(flux submit --wait-event=alloc sleep 300) &&
	pamtest_systemd_user -u ${USER} >su-job.out 2>&1 &&
	test_debug "cat su-job.out" &&
	grep "admitting uid=${MY_UID} with active job" su-job.out
'
test_expect_success 'pam_flux: systemd-user does not admit another user' '
	test_must_fail pamtest_systemd_user -u nobody >su-nobody.out 2>&1 &&
	test_debug "cat su-nobody.out" &&
	grep "ignoring" su-nobody.out &&
	flux cancel $jobid &&
	flux job wait-event -vt 15 $jobid free
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores stale marker with no lock file' '
	touch ${LOCK_DIR}/uid.${MY_UID}.active &&
	test_must_fail test -e ${LOCK_DIR}/uid.${MY_UID}.lock &&
	test_must_fail pamtest_systemd_user -u ${USER} >su-stale.out 2>&1 &&
	test_debug "cat su-stale.out" &&
	grep "no active job for uid=${MY_UID}, ignoring" su-stale.out
'
test_expect_success FLOCK 'pam_flux: systemd-user admits marker while lock is held' '
	pamtest_systemd_user_locked -u ${USER} >su-marker.out 2>&1 &&
	test_debug "cat su-marker.out" &&
	grep "admitting uid=${MY_UID} with active marker" su-marker.out
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores stale marker with unlocked lock file' '
	test -f ${LOCK_DIR}/uid.${MY_UID}.lock &&
	test_must_fail pamtest_systemd_user -u ${USER} >su-stale2.out 2>&1 &&
	test_debug "cat su-stale2.out" &&
	grep "no active job for uid=${MY_UID}, ignoring" su-stale2.out
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores marker of another user' '
	test_must_fail pamtest_systemd_user_locked -u nobody >su-marker2.out 2>&1 &&
	test_debug "cat su-marker2.out" &&
	grep "ignoring" su-marker2.out
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores marker in group-writable lock dir' '
	chmod 0770 ${LOCK_DIR} &&
	test_must_fail pamtest_systemd_user_locked -u ${USER} >su-marker3.out 2>&1 &&
	test_debug "cat su-marker3.out" &&
	grep "must not be group/other writable" su-marker3.out &&
	grep "no active job for uid=${MY_UID}, ignoring" su-marker3.out
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores marker that is a symlink' '
	chmod 0700 ${LOCK_DIR} &&
	rm ${LOCK_DIR}/uid.${MY_UID}.active &&
	touch marker-target &&
	ln -s $(pwd)/marker-target ${LOCK_DIR}/uid.${MY_UID}.active &&
	test_must_fail pamtest_systemd_user_locked -u ${USER} >su-marker4.out 2>&1 &&
	test_debug "cat su-marker4.out" &&
	grep "is not a regular file" su-marker4.out
'
test_expect_success FLOCK 'pam_flux: systemd-user ignores marker in symlinked lock dir' '
	rm ${LOCK_DIR}/uid.${MY_UID}.active &&
	touch ${LOCK_DIR}/uid.${MY_UID}.active &&
	ln -s ${LOCK_DIR} lock-dir-link &&
	cat <<-EOF >systemd-user &&
	auth    required   pam_localuser.so
	account sufficient ${PAM_FLUX_PATH} uri=${FLUX_URI} debug lock-dir=$(pwd)/lock-dir-link
	account required   pam_deny.so
	EOF
	test_must_fail pamtest_systemd_user_locked -u ${USER} >su-marker5.out 2>&1 &&
	test_debug "cat su-marker5.out" &&
	grep "is not a directory" su-marker5.out
'
test_expect_success 'pam_flux: systemd-user uses /run/flux-pam by default' '
	cat <<-EOF >systemd-user &&
	auth    required   pam_localuser.so
	account sufficient ${PAM_FLUX_PATH} uri=${FLUX_URI} debug
	account required   pam_deny.so
	EOF
	test_must_fail pamtest_systemd_user -u ${USER} >su-default.out 2>&1 &&
	test_debug "cat su-default.out" &&
	grep "/run/flux-pam/uid.${MY_UID}.active" su-default.out
'
test_done
