###############################################################
# Copyright 2024 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

# Configuration file for the Sphinx documentation builder.
#
# This file only contains a selection of the most common options. For a full
# list see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Path setup --------------------------------------------------------------

# If extensions (or modules to document with autodoc) are in another directory,
# add these directories to sys.path here. If the directory is relative to the
# documentation root, use os.path.abspath to make it absolute, like shown here.
#
import sys

# add `manpages` directory to sys.path
import pathlib

sys.path.append(str(pathlib.Path(__file__).absolute().parent))

from manpages import man_pages
import docutils.nodes

# -- Project information -----------------------------------------------------

project = "flux-pam"
copyright = """Copyright 2024 Lawrence Livermore National Security, LLC and Flux developers.

SPDX-License-Identifier: LGPL-3.0"""

# -- General configuration ---------------------------------------------------

# Add any paths that contain templates here, relative to this directory.
templates_path = ["_templates"]

# List of patterns, relative to source directory, that match files and
# directories to ignore when looking for source files.
# This pattern also affects html_static_path and html_extra_path.
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

master_doc = "index"
source_suffix = ".rst"

extensions = ["sphinx.ext.intersphinx", "sphinx.ext.napoleon", "domainrefs"]

domainrefs = {
    "linux:man5": {
        "text": "%s(5)",
        "url": "http://man7.org/linux/man-pages/man5/%s.5.html",
    },
    "linux:man7": {
        "text": "%s(7)",
        "url": "http://man7.org/linux/man-pages/man7/%s.7.html",
    },
    "linux:man8": {
        "text": "%s(8)",
        "url": "http://man7.org/linux/man-pages/man8/%s.8.html",
    },
    "core:man5": {
        "text": "%s(5)",
        "url": "https://flux-framework.readthedocs.io/projects/flux-core/en/latest/man5/%s.html",
    },
}

# Disable "smartquotes" to avoid things such as turning long-options
#  "--" into en-dash in html output, which won't make much sense for
#  manpages.
smartquotes = False

def man_role(name, rawtext, text, lineno, inliner, options={}, content=[]):
    section = int(name[-1])
    page = None
    for man in man_pages:
        if man[1] == text and man[4] == section:
            page = man[0]
            break
    if page == None:
        page = "man7/flux-undocumented"
        section = 7

    node = docutils.nodes.reference(
        rawsource=rawtext,
        text=f"{text}({section})",
        refuri=f"../{page}.html",
        **options,
    )
    return [node], []

# launch setup
def setup(app):
    for section in [ 1, 3, 5, 7, 8 ]:
        app.add_role(f"man{section}", man_role)

# ReadTheDocs runs sphinx without first building Flux, so the cffi modules in
# `_flux` will not exist, causing import errors.  Mock the imports to prevent
# these errors.


# -- Options for HTML output -------------------------------------------------

# The theme to use for HTML and HTML Help pages.  See the documentation for
# a list of builtin themes.
#
html_theme = "sphinx_rtd_theme"

# Add any paths that contain custom static files (such as style sheets) here,
# relative to this directory. They are copied after the builtin static files,
# so a file named "default.css" will overwrite the builtin "default.css".
# html_static_path = ['_static']

# -- Options for Intersphinx -------------------------------------------------

intersphinx_mapping = {
    "core": (
        "https://flux-framework.readthedocs.io/projects/flux-core/en/latest/",
        None,
    ),
    "rfc": (
        "https://flux-framework.readthedocs.io/projects/flux-rfc/en/latest/",
        None,
    ),
}
