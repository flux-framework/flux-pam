FROM fluxrm/flux-core:focal

ARG USER=fluxuser
ARG UID=1000
ARG GID=1000

RUN \
 if test "$USER" != "fluxuser"; then  \
      sudo groupadd -g $UID $USER \
   && sudo useradd -g $USER -u $UID -d /home/$USER -m $USER \
   && sudo sh -c "printf \"$USER ALL= NOPASSWD: ALL\\n\" >> /etc/sudoers" \
   && sudo adduser $USER sudo ; \
 fi

RUN sudo apt update \
 && sudo apt install -yy libpam-dev libpam-wrapper \
 && sudo rm -rf /var/lib/apt/lists/*

USER $USER
WORKDIR /home/$USER

