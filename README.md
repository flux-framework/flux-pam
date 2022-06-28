## flux-pam

This repo contains the `pam_flux.so` module, a PAM for allowing access to
nodes on which users have an active Flux job. Use of this module requires
that Flux is being used as the system resource manager.

### Installation

The `pam_flux` PAM module requires PAM development libraries to build. For
example, `pam-devel` on RedHat based systems or `libpam-dev` on Debian
based hosts. This is an autotools project, so recent versions of `autoconf`,
`automake`, and `libtool` are also requied.

Once the prerequisites have been installed, build with
```
./autogen.sh
./configure --prefix=/usr
make
make install
```

By default the `pam_flux` module will be installed to `$libdir/security`
(e.g. a common location is `/usr/lib64/security`). If a different location
is desired, use the `--enable-securedir=DIR` option to `configure`.

### Configuration

To use the PAM module, add it as an `account` provider in your PAM stack,
e.g.:

```
account  sufficient pam_flux.so
```
