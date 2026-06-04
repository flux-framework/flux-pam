#!/bin/bash
#
#  Run flux-pam tests in a systemd-enabled container
#

PROJECT=flux-pam
WORKDIR=/usr/src
MOUNT_HOME_ARGS="--volume=$HOME:/home/$USER -e HOME"
JOBS=2
IMAGE="el8"

declare -r prog=${0##*/}
die() { echo -e "$prog: $@"; exit 1; }

declare -r long_opts="help,no-home,no-cache,jobs:,image:,interactive"
declare -r short_opts="hrj:i:I"
declare -r usage="
Usage: $prog [OPTIONS]\n\
Run flux-pam system tests in systemd-enabled container\n\
\n\
Options:\n\
 -h, --help                    Display this message\n\
 -j, --jobs=N                  Value for make -j (default=$JOBS)\n\
 -i, --image=NAME              Base image name (el8, el10, etc., default=$IMAGE)\n\
 -I, --interactive             Run interactive shell in container\n\
     --no-home                 Skip mounting the host home directory\n\
     --no-cache                Run docker build with --no-cache option\n\
"

# check if running in OSX
if [[ "$(uname)" == "Darwin" ]]; then
    # BSD getopt
    GETOPTS=`/usr/bin/getopt $short_opts -- $*`
else
    # GNU getopt
    GETOPTS=`/usr/bin/getopt -u -o $short_opts -l $long_opts -n $prog -- $@`
    if [[ $? != 0 ]]; then
        die "$usage"
    fi
    eval set -- "$GETOPTS"
fi

while true; do
    case "$1" in
      -h|--help)     echo -ne "$usage";          exit 0  ;;
      -j|--jobs)     JOBS="$2";                  shift 2 ;;
      -i|--image)    IMAGE="$2";                 shift 2 ;;
      --no-home)     MOUNT_HOME_ARGS="";         shift   ;;
      --no-cache)    NOCACHE="--no-cache";       shift   ;;
      -I|--interactive) INTERACTIVE="-ti";       shift   ;;
      --)            shift; break;                       ;;
      *)             die "Invalid option '$1'\n$usage"   ;;
    esac
done

TOP=$(git rev-parse --show-toplevel 2>&1) \
    || die "not inside $PROJECT git repository!"
which podman >/dev/null \
    || die "unable to find podman binary!"
which docker >/dev/null \
    || die "unable to find docker binary!"

. ${TOP}/src/test/checks-lib.sh

# Force memory and cpuset controllers to be delegated in Github actions only
if test "$GITHUB_ACTIONS" = "true"; then
    # Disable apparmor for unix-chkpwd and sudo
    sudo apparmor_parser -R /etc/apparmor.d/unix-chkpwd 2>/dev/null || true
    sudo apparmor_parser -R /etc/apparmor.d/sudo 2>/dev/null || true

    for controller in memory cpuset; do
        grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control \
          || echo "+$controller" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
    done
fi

# Now check for controllers in subtree_control and warn if not present
for controller in memory cpuset; do
  if ! grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control; then
      echo "::warning:: cgroup controller '$controller' not delegated on host," \
           "resource control tests may not work properly"
  fi
done

# Build the base image with flux-pam dependencies
checks_group "Building base image flux-pam:$IMAGE" \
  docker build \
    ${NOCACHE} \
    --build-arg USER=$USER \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    -t flux-pam:$IMAGE \
    -f ${TOP}/src/test/docker/$IMAGE/Dockerfile \
    ${TOP} \
    || die "docker build of base image failed"

# Usage: podman_pull IMAGE
# Pull image from docker if missing or checksum out of date
podman_pull() {
  DOCKER_ID=$(docker inspect --format '{{.Id}}' $1 2>/dev/null)
  PODMAN_ID=$(sudo podman inspect --format '{{.Id}}' $1 2>/dev/null)
  if [ "$DOCKER_ID" != "$PODMAN_ID" ]; then
      checks_group "Moving $1 from docker to podman" \
          sudo podman pull docker-daemon:$1
  fi
}

podman_pull flux-pam:$IMAGE

# Build the systemd-enabled test image
checks_group "Building systemd test image for user $USER $(id -u) group=$(id -g)" \
  sudo podman build \
    ${NOCACHE} \
    --build-arg IMAGE=flux-pam:$IMAGE \
    --build-arg USER=$USER \
    --build-arg UID=$(id -u) \
    --build-arg GID=$(id -g) \
    -t flux-pam:systest \
    ${TOP}/src/test/docker/systest \
    || die "docker build of systest image failed"

NAME=flux-pam-systest-$$
checks_group "Launching system instance container $NAME" \
  sudo podman run -d --rm \
    --name=$NAME \
    --privileged \
    --systemd=always \
    --volume=/sys/fs/cgroup:/sys/fs/cgroup:rw \
    --security-opt apparmor=unconfined \
    --hostname=flux-pam-test \
    --network=host \
    --workdir=$WORKDIR \
    $MOUNT_HOME_ARGS \
    --volume=$TOP:$WORKDIR \
    flux-pam:systest \
    || die "podman run of systest container failed"

# Wait for systemd to be ready
sleep 2

#  Start user@uid.service service for tests:
#
checks_group "Starting user service user@$(id -u).service" \
  sudo podman exec $NAME \
    systemctl start user@$(id -u).service \
    || die "podman start user@$(id -u).service failed"

# We want checks to fail if cgroups aren't properly delegated in Github Actions
if test "$GITHUB_ACTIONS" = "true"; then
  for controller in memory cpuset; do \
    sudo podman exec $NAME \
      grep -qw "$controller" /sys/fs/cgroup/user.slice/cgroup.subtree_control \
      || checks_die "cgroup controller '$controller' not delegated in " \
                    "container user.slice, resource control will not work"; \
  done
fi

# Run the test suite (hardcoded commands)
if test -n "$INTERACTIVE"; then
  msg="Executing interactive shell in system instance container"
  TESTCMD="bash"
else
  msg="Running test suite"
  TESTCMD="bash -c './autogen.sh && ./configure && make -j $JOBS check'"
fi

checks_group "$msg" \
  sudo podman exec \
    "${INTERACTIVE}" \
    -u $USER:$(id -g) \
    ${CC+-e CC=$CC} \
    ${CXX+-e CXX=$CXX} \
    ${LDFLAGS+-e LDFLAGS=$LDFLAGS} \
    ${CFLAGS+-e CFLAGS=$CFLAGS} \
    ${CPPFLAGS+-e CPPFLAGS=$CPPFLAGS} \
    -e GCOV=$GCOV \
    -e CCACHE_CPP2=$CCACHE_CPP2 \
    -e CCACHE_READONLY=$CCACHE_READONLY \
    -e COVERAGE=$COVERAGE \
    -e CPPCHECK=$CPPCHECK \
    -e DISTCHECK=$DISTCHECK \
    -e RECHECK=$RECHECK \
    -e chain_lint=$chain_lint \
    -e JOBS=$JOBS \
    -e USER=$USER \
    -e PROJECT=$PROJECT \
    -e CI=$CI \
    -e TAP_DRIVER_QUIET=$TAP_DRIVER_QUIET \
    -e FLUX_PAM_TEST_TIMEOUT=$FLUX_TEST_TIMEOUT \
    -e FLUX_PAM_TEST_USER=$FLUX_PAM_TEST_USER \
    -e FLUX_TESTS_LOGFILE=t \
    -e HOME=/home/$USER \
    -e XDG_RUNTIME_DIR=/run/user/$(id -u) \
    -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
    -e SYSTEM=t \
    -w $WORKDIR \
    $NAME \
    $TESTCMD
RC=$?

sudo podman stop $NAME

if test $RC -ne 0; then
    die "system tests failed with rc=$RC"
fi

# vi: ts=4 sw=4 expandtab
