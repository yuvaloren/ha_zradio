# tests/Dockerfile — the tests' own Linux, for a machine that is not one (macOS: BSD sed and stat, no flock).
# Used by tests/docker.sh. Debian 13 is what the radio VMs and the Proxmox nodes run. The packages are those of
# .github/workflows/tests.yml, plus what GitHub's runner already has (systemd-analyze, ss, cloud-init), so that no
# check is skipped here.
FROM debian:13
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      shellcheck python3 python3-yaml openssh-client ser2net socat keepalived util-linux \
      systemd iproute2 cloud-init procps ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m dev
# Not root: the kit's "are you root" refusals are part of what is tested.
USER dev
WORKDIR /home/dev/ha_zradio
# The repo is mounted read-only at /src and copied, so a run leaves nothing behind in the clone.
ENTRYPOINT ["bash", "-c", "cp -R /src/. . && { [ $# -gt 0 ] || shellcheck -S warning get.sh install.sh guest/install.sh tests/*.sh; } && exec bash tests/run.sh \"$@\"", "--"]
