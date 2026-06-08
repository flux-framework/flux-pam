###############################################################
# Copyright 2014 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

import argparse
import os
import subprocess
import sys

script_dir = os.path.dirname(os.path.abspath(__file__))

# ported from sharness.d/01-setup.sh
# In flux-pam, we use the installed flux from FLUX_BUILD_DIR or PATH
if "FLUX_BUILD_DIR" in os.environ:
    # Use flux from build environment (set by AM_TESTS_ENVIRONMENT)
    flux_exe = os.path.join(os.environ["FLUX_BUILD_DIR"], "bin", "flux")
    if not os.path.exists(flux_exe):
        # Fall back to installed flux in PATH
        import shutil
        flux_exe = shutil.which("flux") or "/tmp/flux/bin/flux"
else:
    # Use flux from PATH
    import shutil
    flux_exe = shutil.which("flux") or "/tmp/flux/bin/flux"

sys.path.append(script_dir + "/tap")


#  Ignore -v, --verbose and --root options so that python test scripts
#   can absorb the same options as sharness tests. Later, something could
#   be done with these options, but for now they are dropped silently.
parser = argparse.ArgumentParser()
parser.add_argument("--debug", "-d", action="store_true")
parser.add_argument("--root", metavar="PATH", type=str)
args, remainder = parser.parse_known_args()

sys.argv[1:] = remainder


def is_file(fpath):
    return os.path.isfile(fpath)


def sanitize_env(env):
    """Sanitize environment variables in subflux env that may affect tests"""
    sanitize = (
        "FLUX_SHELL_RC_PATH",
        "FLUX_RC_EXTRA",
        "FLUX_CONF_DIR",
        "FLUX_JOB_CC",
        "FLUX_F58_FORCE_ASCII",
        "FLUX_MODPROBE_PATH",
        "FLUX_URI_RESOLVE_LOCAL",
    )
    for var in list(env.keys()):
        if var.startswith(("PMI", "SLURM")) or var in sanitize:
            del env[var]


def rerun_under_flux(size=1, personality="full"):
    try:
        if os.environ["IN_SUBFLUX"] == "1":
            return True
    except KeyError:
        pass

    child_env = dict(**os.environ)
    child_env["IN_SUBFLUX"] = "1"

    # Set build dir if available (for flux-pam testing)
    if "FLUX_BUILD_DIR" in os.environ:
        child_env["FLUX_BUILD_DIR"] = os.environ["FLUX_BUILD_DIR"]

    # Ensure flux.pam in builddir overrides installed flux.pam
    child_env["FLUX_PYTHONPATH_PREPEND"] = (
        script_dir + "/../../src/bindings/python"
    )

    sanitize_env(child_env)

    command = [flux_exe, "start", "--test-size", str(size)]
    # flux-pam doesn't use custom rc scripts, so ignore personality

    command.extend([sys.executable, sys.argv[0]])

    p = subprocess.Popen(
        command, env=child_env, bufsize=-1, stdout=sys.stdout, stderr=sys.stderr
    )
    p.wait()
    if p.returncode > 0:
        sys.exit(p.returncode)
    elif p.returncode < 0:
        sys.exit(128 + -p.returncode)
    return False
