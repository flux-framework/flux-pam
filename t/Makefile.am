AM_CFLAGS = \
        $(WARNING_CFLAGS)

AM_TESTS_ENVIRONMENT = \
	export FLUX_BUILD_DIR="$(abs_top_builddir)"; \
	export PATH="$(dir $(FLUX)):$$PATH"; \
	export PYTHONPATH="$(abs_top_builddir)/src/bindings/python:$(abs_top_srcdir)/src/bindings/python:$(abs_top_srcdir)/t/python/tap:$$PYTHONPATH"; \
	export PYTHON="$(FLUX) python";

TEST_EXTENSIONS = .t .py
T_LOG_DRIVER = env AM_TAP_AWK='$(AWK)' $(SHELL) \
        $(top_srcdir)/config/tap-driver.sh
PY_LOG_DRIVER = $(FLUX) python $(top_srcdir)/config/tap-driver.py

clean-local:
	rm -fr trash-directory.* test-results .prove *.broker.log *.output

TESTS = t0001-pam_flux.t \
	python/t0001-pam.py

dist_check_SCRIPTS = $(TESTS)

check_PROGRAMS   = pamtest
pamtest_SOURCES  = pamtest.c
pamtest_LDADD    = -lpam -lpam_misc

EXTRA_DIST = \
	scripts \
	sharness.sh \
	sharness.d \
	python/subflux.py \
	python/tap
