from golang:1.25-trixie as builder
env CGO_ENABLED=1

arg TAG

workdir /app
run git clone -b ${TAG} https://tangled.org/@tangled.org/core .
run go build -o /usr/bin/knot -ldflags '-s -w' ./cmd/knot

from debian:trixie-slim
env KNOT_REPO_SCAN_PATH=/home/git/repositories
expose 5555
expose 22

label org.opencontainers.image.description='knotserver'
label org.opencontainers.image.source='https://tangled.org/ripta.i6y.me/knot-docker-debian'
label org.opencontainers.image.url='https://tangled.org'
label org.opencontainers.image.licenses='MIT'

arg UID=2357
arg GID=2357

run apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git openssh-server openssl runit \
    && rm -rf /var/lib/apt/lists/*

copy rootfs-debian /
run chmod 755 /etc
run chmod 755 /etc/knot/sv/sshd/run /etc/knot/sv/knotserver/run \
        /usr/local/bin/keys-wrapper /usr/local/sbin/boot

run groupadd -g $GID -f git
run useradd -u $UID -g $GID -d /home/git git
run echo "git:$(openssl rand -hex 16)" | chpasswd
run mkdir -p /home/git/repositories && chown -R git:git /home/git
copy --from=builder /usr/bin/knot /usr/bin
run mkdir /app && chown -R git:git /app

healthcheck --interval=60s --timeout=30s --start-period=5s --retries=3 \
    cmd curl -f http://localhost:5555 || exit 1

entrypoint ["/usr/local/sbin/boot"]
