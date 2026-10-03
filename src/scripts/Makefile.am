fluxlibexecprologdir = $(fluxlibexecdir)/prolog.d
fluxlibexechousekeepingdir = $(fluxlibexecdir)/housekeeping.d
fluxlibexecprolog_SCRIPTS = inst/flux-pam-prolog
fluxlibexechousekeeping_SCRIPTS = inst/flux-pam-housekeeping

EXTRA_DIST = \
	flux-pam-prolog.in \
	flux-pam-housekeeping.in

CLEANFILES = \
	$(fluxlibexecprolog_SCRIPTS) \
	$(fluxlibexechousekeeping_SCRIPTS)

# CLEANFILES removes the scripts but leaves the directory holding them.
clean-local:
	-rmdir inst 2>/dev/null || :

# The scripts consult _FLUX_PAM_TEST_* to redirect systemctl and loginctl
# at a mock. The testsuite runs them from the build tree, so the installed
# copies have no use for the overrides: replace each lookup with the path
# configure found, leaving nothing in the installed script that can steer
# what it executes.
#
# Built into inst/ rather than under a suffix so automake installs them
# under their own names, applying $(transform) as it does for any script.
#
# Generated from the configured script, not from the .in template, so the
# @SYSTEMCTL@ and @LOGINCTL@ substitutions are already in place.
#
# The path may be empty: configure only looks for systemctl and loginctl
# when libsystemd is present, so a build without it substitutes "". The
# scripts are installed either way and must still have the lookups
# removed, so match an empty path too.
STRIP_TEST_HOOKS = \
	$(SED) -E \
	  's|^([A-Z]+) = os\.environ\.get\("_FLUX_PAM_TEST_[A-Z]+", ("[^"]*")\)$$|\1 = \2|'

# Fail if a lookup survives the rewrite. A pattern that stops matching,
# say after the assignments are reformatted, would otherwise ship the
# overrides while the build still succeeds. .DELETE_ON_ERROR removes the
# partial target, so a failed strip cannot leave one behind.
.DELETE_ON_ERROR:

inst/%: %
	$(AM_V_at)$(MKDIR_P) inst
	$(AM_V_GEN)$(STRIP_TEST_HOOKS) $< >$@
	$(AM_V_at)if grep -q '_FLUX_PAM_TEST_' $@; then \
	  echo "$@: failed to strip test path overrides" >&2; \
	  exit 1; \
	fi
	$(AM_V_at)chmod +x $@
