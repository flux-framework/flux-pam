AM_CFLAGS = \
        $(WARNING_CFLAGS)

TEST_EXTESIONS = .t
T_LOG_DRIVER = env AM_TAP_AWK='$(AWK)' $(SHELL) \
        $(top_srcdir)/config/tap-driver.sh

clean-local:
	rm -fr trash-directory.* test-results .prove *.broker.log *.output

TESTS = t0001-pam_flux.t

dist_check_SCRIPTS = $(TESTS)

check_PROGRAMS   = pamtest
pamtest_SOURCES  = pamtest.c
pamtest_LDADD    = -lpam -lpam_misc

EXTRA_DIST = \
	sharness.sh \
	sharness.d
