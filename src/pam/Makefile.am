AM_CFLAGS = \
	$(WARNING_CFLAGS) 

pamdir = $(SECUREDIR)

pam_LTLIBRARIES = \
	pam_flux.la

pam_flux_la_SOURCES = \
	pam_flux.c

pam_flux_la_CPPFLAGS = \
	-I $(top_srcdir) \
	$(AM_CFLAGS) \
	$(FLUX_CORE_CFLAGS) \
	$(FLUX_IDSET_CFLAGS) \
	$(JANSSON_CFLAGS)

pam_flux_la_LDFLAGS = \
	-module --export-dynamic -avoid-version

pam_flux_la_LIBADD = \
	-lpam \
	$(FLUX_CORE_LIBS) \
	$(FLUX_IDSET_LIBS) \
	$(JANSSON_LIBS)
