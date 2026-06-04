AM_CFLAGS = \
	$(WARNING_CFLAGS) 

pamdir = $(SECUREDIR)

pam_LTLIBRARIES = \
	pam_flux.la

pam_flux_la_SOURCES = \
	pam_flux.c

if HAVE_LIBSYSTEMD
SYSTEMD_CFLAGS_OPT = $(LIBSYSTEMD_CFLAGS)
SYSTEMD_LIBS_OPT = $(LIBSYSTEMD_LIBS)
else
SYSTEMD_CFLAGS_OPT =
SYSTEMD_LIBS_OPT =
endif

pam_flux_la_CPPFLAGS = \
	-I $(top_srcdir) \
	$(AM_CFLAGS) \
	$(FLUX_CORE_CFLAGS) \
	$(FLUX_IDSET_CFLAGS) \
	$(JANSSON_CFLAGS) \
	$(SYSTEMD_CFLAGS_OPT)

pam_flux_la_LDFLAGS = \
	-module --export-dynamic -avoid-version

pam_flux_la_LIBADD = \
	-lpam \
	$(FLUX_CORE_LIBS) \
	$(FLUX_IDSET_LIBS) \
	$(JANSSON_LIBS) \
	$(SYSTEMD_LIBS_OPT)
