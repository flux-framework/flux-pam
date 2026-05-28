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

# vi: ts=4 sw=4 expandtab
