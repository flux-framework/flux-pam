"""flux namespace package"""

from pkgutil import extend_path

__path__ = extend_path(__path__, __name__)

import os

# Re-export from installed flux-core by executing its __init__.py
# in our namespace
import sys

thisdir = os.path.dirname(os.path.dirname(__file__))

# Find installed flux package
for path in sys.path:
    if os.path.abspath(path) == os.path.abspath(thisdir):
        continue
    flux_init = os.path.join(path, "flux", "__init__.py")
    if os.path.exists(flux_init):
        # Execute installed __init__.py in our namespace so its
        # definitions become ours
        with open(flux_init) as f:
            exec(f.read(), globals())
        break
