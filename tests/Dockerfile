# tests/Dockerfile — the tests' own Linux, for a machine that is not one (macOS: BSD sed and stat, no flock).
# Used by tests/docker.sh. Debian 13 is what the radio VMs and the Proxmox nodes run. The packages are those of
# .github/workflows/tests.yml, plus what GitHub's runner already has, so that no check is skipped here and none meets
# another machine here than there: systemd-analyze, ss, cloud-init; an SSH server with its host keys in /etc/ssh
# (openssh-server: the 0.1.0 run failed on the runner over a host key this container did not have); wget.
FROM debian:13
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      shellcheck python3 python3-yaml openssh-client openssh-server ser2net socat keepalived util-linux \
      systemd iproute2 cloud-init procps ca-certificates curl wget git jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m dev
# (the tests that need this image to be like the runner say so when it is not: tests/t-vote.sh)
ENV ZRADIO_TESTS_IMAGE=1
# Not root: the kit's "are you root" refusals are part of what is tested.
USER dev
WORKDIR /home/dev/ha_zradio
# The repo is mounted read-only at /src and copied, so a run leaves nothing behind in the clone.
ENTRYPOINT ["bash", "-c", "cp -R /src/. . && { [ $# -gt 0 ] || bash tests/shellcheck.sh; } && exec bash tests/run.sh \"$@\"", "--"]
