# Test image: a freshly installed system with systemd, like a real server.
# Built and started by .github/workflows/ci.yml, once for each system of its
# list (IMAGE: debian:bookworm, debian:trixie…).
ARG IMAGE=debian:bookworm
FROM ${IMAGE}

ENV container=docker

# The minimum of a freshly installed VPS (systemd, SSH), plus the tools the
# tests need to play the part of a client (sshpass, ping, nc). qrencode plays
# a package that was there before seedtunnel: removing the VPN must keep it.
# Ubuntu Server comes with ufw (off): it is there too.
RUN if grep -q '^ID=ubuntu' /etc/os-release; then extra=ufw; else extra=; fi \
    && rm -f /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus iproute2 procps kmod ca-certificates curl \
        openssh-server openssh-client sshpass iputils-ping netcat-openbsd qrencode $extra \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask getty@tty1.service console-getty.service systemd-firstboot.service

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
