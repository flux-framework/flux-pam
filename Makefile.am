ACLOCAL_AMFLAGS = -I config

EXTRA_DIST = \
	LICENSE \
	NEWS.md \
	README.md \
	NOTICE.LLNS \
	CONTRIBUTING.md \
	MAINTAINERS.md \
	config/tap-driver.sh \
	config/tap-driver.py \
	debian \
	scripts

SUBDIRS = \
	src/pam \
	src/bindings/python \
	src/scripts \
	etc \
	doc \
	t

deb: debian scripts/debbuild.sh
	@$(top_srcdir)/scripts/debbuild.sh $(abs_top_srcdir)

clean-local:
	@rm -rf debbuild
