# submit job as guest user using FLUX_HANDLE_USERID and sign-as.py
# Usage: submit_as_guest DURATION OPTIONS...
#
submit_as_guest() {
    fake_userid=${FAKE_USERID:-42}
    DURATION=$1
    shift
    flux run --dry-run \
      --setattr=exec.test.run_duration=\"$duration\" "$@" | \
        flux python ${SHARNESS_TEST_SRCDIR}/scripts/sign-as.py $fake_userid \
          >job.signed &&
    FLUX_HANDLE_USERID=$fake_userid \
      flux job submit --flags=signed job.signed
}

# Acquire exclusive lock for systemd user service manipulation
# Call this after determining TEST_USER and TEST_UID, and after
# test_under_flux (to avoid losing the lock on re-exec)
#
# Usage: test_systemd_user_lock ${TEST_UID}
#
# This prevents multiple flux-pam tests (even from different build
# directories) from manipulating the same systemd user service in
# parallel, which would cause test failures.
test_systemd_user_lock() {
    uid="$1"
    lockfile="/tmp/flux-pam-test-uid-${uid}.lock"

    # Check if flock is available
    if ! command -v flock >/dev/null 2>&1; then
        # flock not available, skip locking (test may race)
        return 0
    fi

    # Try to open lock file on fd 9
    if eval "exec 9>${lockfile}" 2>/dev/null; then
        # Acquire exclusive lock, wait up to 60 seconds
        if ! flock -x -w 60 9 2>/dev/null; then
            skip_all="could not acquire user lock for uid ${uid}"
            test_done
        fi
        # Lock acquired successfully on fd 9, will be held until test exits
    fi
    # If we can't open the file or flock fails in a way we can't detect,
    # just continue without locking (test may race)
}

# Set a HAVE_SYSTEMD prereq (may not be available in ci)
if systemctl --version >/dev/null 2>&1 && \
   systemctl status >/dev/null 2>&1; then
    test_set_prereq HAVE_SYSTEMD
fi

# vi: ts=4 sw=4 expandtab
