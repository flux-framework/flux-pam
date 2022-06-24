FROM fluxrm/flux-core:fedora35

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
 && sudo dnf -y install pam-devel

RUN cd /tmp \
 && mkdir pam_wrapper \
 && cd pam_wrapper \
 && wget -O - https://ftp.samba.org/pub/cwrap/pam_wrapper-1.1.4.tar.gz \
     | tar xvz --strip-components 1 \
 && mkdir obj \
 && cd obj \
 && cmake -DCMAKE_INSTALL_PREFIX=/usr -DLIB_SUFFIX=64 .. \
 && make \
 && sudo make install

USER $USER
WORKDIR /home/$USER

