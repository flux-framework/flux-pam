flux-pam Documentation
======================

flux-pam is a PAM module for the `Flux <https://flux-framework.org>`_
resource management framework. It restricts node access to users with active
Flux jobs on the node and, when systemd integration is enabled, manages user
slice resource constraints.

Overview
--------

flux-pam provides two cooperating components:

**pam_flux.so** — A PAM module with account and session management functions.
The account module grants or denies login access based on whether the user
has an active Flux job on the node. The session module places admitted logins
into a transient systemd scope under the user's managed slice, ensuring SSH
sessions share the same resource constraints as the job.

**Prolog and housekeeping scripts** — Run on each compute node at job start
and completion to manage the ``user@UID.service`` lifecycle and apply CPU,
memory, and device limits to the user's systemd slice.

Key Features
------------

- **Access control**: Restrict SSH access to users with active jobs
- **Guest access**: Allow users into multi-user Flux instances
- **Resource containment**: Constrain login sessions to allocated resources
- **systemd integration**: Manage user slices and service lifecycle
- **cgroup v2 support**: Apply CPU, memory, and device constraints

Quick Start
-----------

For basic access control, add to ``/etc/pam.d/sshd``:

.. code-block:: text

   account  sufficient  pam_flux.so

For full session management with resource constraints, see :ref:`pam_flux(8) <man-pages>`.

.. _man-pages:

Manual Pages
============

.. toctree::
   :maxdepth: 2

   man5/index
   man8/index
