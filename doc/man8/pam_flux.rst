===========
pam_flux(8)
===========

SYNOPSIS
========

  :command:`pam_flux.so` [allow-guest-user]

DESCRIPTION
===========

This module can be used to restrict access to compute nodes of a cluster
where Flux is being used as the system resource manager. By default, users
are granted access only if they have a currently active job assigned
to the node. If this is not the case, access is denied with the message:
::

  Access denied: user [username] has no active jobs on this node

To use this module, add it as an account provider in your PAM stack,
with the appropriate control field, e.g.::

  account sufficient pam_flux.so [OPTIONS]

OPTIONS
=======

allow-guest-user
  (optional) This option additionally allows any user access to the node if
  the following conditions are met:

   - the system instance owner (as encoded in the security.owner attribute)
     has an active job on the current node
   - the current node is rank 0 of the instance owner job
   - the job is an instance of Flux
   - the PAM module can query the instance configuration, and
     ``access.allow-guest-user`` is set to ``true``.

EXAMPLE
=======

::

    account sufficient pam_flux.so allow-guest-user

RESOURCES
==========

.. include:: common/resources.rst

SEE ALSO
========

:core:man5:`flux-config-access`
:linux:man5:`pam.d`
:linux:man5:`pam.conf`
:linux:man7:`pam`
