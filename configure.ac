##
# Prologue
##
AC_INIT([flux-pam],
        m4_esyscmd([git describe --always | awk '/.*/ {sub(/^v/, ""); printf "%s",$1; exit}']))

AC_CONFIG_AUX_DIR([config])
AC_CONFIG_MACRO_DIR([config])
AC_CONFIG_SRCDIR([NEWS.md])
AC_PREFIX_PROGRAM([flux])
AC_CANONICAL_TARGET

AM_INIT_AUTOMAKE([subdir-objects tar-pax foreign])
AM_SILENT_RULES([yes])
AM_MAINTAINER_MODE([enable])

AC_DEFINE([_GNU_SOURCE], 1,
          [Define _GNU_SOURCE so that we get all necessary prototypes])

##
# Generate project versions from PACKAGE_VERSION (set from git describe above)
##
AX_SPLIT_VERSION
AX_POINT_VERSION=$(echo $AX_POINT_VERSION | $SED 's/-.*$//')
AC_SUBST([AX_MAJOR_VERSION])
AC_SUBST([AX_MINOR_VERSION])
AC_SUBST([AX_POINT_VERSION])

##
# Initialize pkg-config for PKG_CHECK_MODULES to avoid conditional issues
##
PKG_PROG_PKG_CONFIG

# Checks for programs
##
AC_PROG_CC
AM_PROG_CC_C_O
AX_COMPILER_VENDOR
AX_COMPILER_VERSION

AS_CASE($ax_cv_c_compiler_vendor,
  [clang | gnu], [
    WARNING_CFLAGS="-Wall -Werror -Wno-strict-aliasing -Wno-error=deprecated-declarations"
  ]
)
AC_SUBST([WARNING_CFLAGS])

LT_INIT

PKG_CHECK_MODULES([JANSSON], [jansson >= 2.10], [], [])
AS_IF([test "x$enable_docs" != "xno"], [
            AM_CHECK_PYMOD(sphinx,
                           [Version(sphinx.__version__) >= Version ('1.6.7')],
                           [sphinx=true],
                           [sphinx=false; AC_MSG_WARN([could not find sphinx to generate docs, version 1.6.7+ required])]
                           )
            AM_CHECK_PYMOD(docutils,
                           [Version(docutils.__version__) >= Version ('0.11.0')],
                           [docutils=true],
                           [docutils=false; AC_MSG_WARN([could not find docutils to generate docs, version 0.11.0+ required])]
                           )
])
#  If --enable-docs=yes, but no doc generator found,
#   then error immediately:
#
#  If --enable-docs=yes, but no doc generator found,
#   then error immediately:
#
AS_IF([test "x$enable_docs" = "xyes" -a "x$sphinx" = "xfalse"],[
  AC_MSG_ERROR([--enable-docs used but no document generator found!])
])
AS_IF([test "x$enable_docs" = "xyes" -a "x$docutils" = "xfalse"],[
  AC_MSG_ERROR([--enable-docs used but docutils not found!])
])
AM_CONDITIONAL([ENABLE_DOCS], [test "x$sphinx" = "xtrue" -a "x$docutils" = "xtrue"])
AC_CHECK_PROG(ASPELL,[aspell],[aspell])

AS_IF([test "x$enable_docs" != "xno"], [
  if test "x$sphinx" = "xfalse"; then
    AC_MSG_WARN([Python Sphinx not found. Manual pages will not be generated.])
  elif test "x$docutils" = "xfalse"; then
    AC_MSG_WARN([Python Docutils not found. Manual pages will not be generated.])
  fi
])

AX_FLUX_CORE

##
# Systemd support
##
AC_ARG_ENABLE([systemd],
  AS_HELP_STRING([--enable-systemd],
    [Enable systemd integration @<:@default=auto@:>@]))

AS_IF([test "x$enable_systemd" != "xno"], [
  PKG_CHECK_MODULES([LIBSYSTEMD], [libsystemd >= 239],
                    [have_libsystemd=yes], [have_libsystemd=no])
  AC_CHECK_HEADER([systemd/sd-bus.h], [have_sd_bus_h=yes], [have_sd_bus_h=no])

  AS_IF([test "x$have_libsystemd" = "xyes" -a "x$have_sd_bus_h" = "xyes"], [
    AC_DEFINE([HAVE_LIBSYSTEMD], [1], [Define if you have libsystemd])

    # Find systemd utilities
    AC_ARG_VAR([SYSTEMCTL], [Path to systemctl])
    AC_PATH_PROG([SYSTEMCTL], [systemctl], [no])
    AS_IF([test "x$SYSTEMCTL" = "xno"], [
      AC_MSG_ERROR([systemctl not found in PATH])
    ])

    AC_ARG_VAR([LOGINCTL], [Path to loginctl])
    AC_PATH_PROG([LOGINCTL], [loginctl], [no])
    AS_IF([test "x$LOGINCTL" = "xno"], [
      AC_MSG_ERROR([loginctl not found in PATH])
    ])
  ], [
    AS_IF([test "x$enable_systemd" = "xyes"], [
      AC_MSG_ERROR([--enable-systemd was given but libsystemd not found])
    ])
    have_libsystemd=no
  ])
], [
  have_libsystemd=no
])

AM_CONDITIONAL([HAVE_LIBSYSTEMD], [test "x$have_libsystemd" = "xyes"])


AC_CHECK_HEADERS_ONCE([security/pam_appl.h])
AC_CHECK_HEADER([security/pam_modules.h], [], [], \
		[#ifdef HAVE_SECURITY_PAM_APPL_H
		# include <security/pam_appl.h>
		#endif
		])
AC_CHECK_LIB([pam], [pam_get_user], [:])
AS_IF([test "x$ac_cv_header_security_pam_modules_h" = "xno" \
       -o "x$ac_cv_lib_pam_pam_get_user" = "xno"], [
  AC_MSG_ERROR([Unable to find the PAM library or the PAM header files])
])

AC_ARG_ENABLE(securedir,
	AS_HELP_STRING([--enable-securedir=DIR],[path to location of PAMs @<:@default=$libdir/security@:>@]),
	SECUREDIR=$enableval, SECUREDIR=$libdir/security)
AC_SUBST(SECUREDIR)

##
# Epilogue
##
AC_CONFIG_FILES( \
  Makefile \
  src/pam/Makefile \
  etc/Makefile \
  doc/Makefile \
  t/Makefile \
)

AC_OUTPUT
