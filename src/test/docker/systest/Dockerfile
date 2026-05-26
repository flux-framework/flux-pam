# This Dockerfile builds a systemd-enabled test image from a base
# flux-pam build image (el8, el10, etc.) that already has build dependencies
ARG IMAGE=flux-pam:el8
FROM $IMAGE

# Container user - should match the user from base image
ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

ENV container docker

STOPSIGNAL SIGRTMIN+3

USER root

VOLUME [ "/sys/fs/cgroup" ]

# Minimal systemd setup
# See: https://hub.docker.com/r/centos/systemd/dockerfile
# Keep systemd-tmpfiles-setup.service and dbus socket units for scope creation
RUN (cd /lib/systemd/system/sysinit.target.wants/; \
     for i in *; \
         do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i; \
      done); \
    rm -f /lib/systemd/system/local-fs.target.wants/*; \
    rm -f /lib/systemd/system/basic.target.wants/*;\
    rm -f /lib/systemd/system/anaconda.target.wants/*;

# Remove unwanted socket units but keep dbus
RUN (cd /lib/systemd/system/sockets.target.wants/ 2>/dev/null && \
     for i in *udev* *initctl*; do rm -f $i 2>/dev/null || true; done) || true

# Unmask systemd-logind - required for creating transient scopes
RUN systemctl unmask systemd-logind.service || true

# Remove sss from nsswitch.conf (sssd not running in container)
RUN sed -i 's/\bsss\b//g' /etc/nsswitch.conf

# Create test user if it doesn't exist
RUN id $USER \
 || ( groupadd -g $UID $USER \
   && useradd -g $USER -u $UID -d /home/$USER -m $USER \
   && printf "$USER ALL=(ALL) NOPASSWD: ALL\\n" >> /etc/sudoers \
   && usermod -G wheel $USER \
 )

# Add additional test users for multi-user testing
RUN for i in $(seq 1 5); do \
      user="user${i}"; \
      uid=$((${UID} + 100 + $i)); \
      printf "Adding ${user}\n"; \
      groupadd -g $uid $user; \
      useradd -g $user -u $uid -d /home/$user -m $user; \
    done

# Add 'nobody' user for pam tests
RUN id nobody || useradd --system -d /nonexistent -s /usr/sbin/nologin nobody

# Add ExecStartPost to user@.service to ensure cgroup delegation
RUN mkdir -p /etc/systemd/system/user@.service.d \
 && printf '[Service]\nDelegate=memory cpuset io pids\n' \
    > /etc/systemd/system/user@.service.d/delegate.conf \
 && printf 'ExecStartPost=+/bin/sh -c "echo +memory +cpuset +io +pids > /sys/fs/cgroup/user.slice/cgroup.subtree_control || true"\n' \
    >> /etc/systemd/system/user@.service.d/delegate.conf

WORKDIR /home/$USER
CMD [ "init" ]
