FROM fluxrm/flux-core:el10

ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

RUN \
 if test "$USER" != "fluxuser"; then  \
      sudo groupadd -g $UID $USER \
   && sudo useradd -g $USER -u $UID -d /home/$USER -m $USER \
   && sudo sh -c "printf \"$USER ALL= NOPASSWD: ALL\\n\" >> /etc/sudoers" \
   && sudo usermod -G wheel $USER \
   && sudo usermod -G wheel fluxuser ; \
 fi

RUN sudo yum -y update \
 && sudo dnf -y install pam-devel pam_wrapper

USER $USER
WORKDIR /home/$USER

