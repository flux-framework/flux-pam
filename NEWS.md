flux-pam version 0.4.0 - 2026-06-08
-----------------------------------

 * doc: add introduction to documentation index (#24)
 * pam: fix `pam_flux.so` interaction with systemd-user PAM service (#23)
 * switch to marker-based slice containment instead of managing user@UID
   service (#26)

flux-pam version 0.3.0 - 2026-06-04
-----------------------------------

 * add systemd user slice management and PAM session containment (#19)
 * support `allow-guest-user` option (#8)
 * doc: include correct license file (#16)
 * doc: copy MAINTAINERS, CONTRIBUTING from flux-core (#14)
 * doc: add `pam_flux(8)` man page (#10)
 * doc: enable readthedocs integration (#20)
 * minor code, build, and CI cleanup (#18)
 * mergify: disable temporary PR branches (#13)
 * testsuite: use `flux cancel` instead of `flux job cancel` (#11)

flux-pam version 0.2.0 - 2023-10-04
-----------------------------------

* remove use of deprecated commands and functions (#5)

flux-pam version 0.1.0 - 2022-06-27
-----------------------------------

* Initial release

