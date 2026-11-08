from rust:1.96-slim-trixie as builder

arg TAG

workdir /src
run apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential cmake perl pkg-config clang mold \
    && rm -rf /var/lib/apt/lists/*
env RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=mold"
run git clone --depth 1 -b ${TAG} https://tangled.org/did:plc:j5hmlfdrwkvtxm7cjmu7j2is .
run cargo build --release --package knot-server --package knot-migrate
run strip target/release/knot-server target/release/knot-migrate

from debian:trixie-slim

# Defaults for running the image on its own. The Kubernetes manifests
# override the paths, because the knot state lives in /data/knot2 there.
env KNOT_SCAN_PATH=/data/repos
env KNOT_LFS_STORE_PATH=/data/lfs
env KNOT_SEALED_KEY_FILE=/data/sealed-keys
env KNOT_SSH_HOST_KEY_FILE=/data/ssh_host_key
env KNOT_MASTER_KEY_ENV=KNOT_MASTER_KEY
env KNOT_PLC_DIRECTORY=https://plc.directory
expose 5555
expose 2222

label org.opencontainers.image.description='knot-server'
label org.opencontainers.image.source='https://tangled.org/ripta.i6y.me/knot-k8s'
label org.opencontainers.image.url='https://tangled.org'
label org.opencontainers.image.licenses='MIT'

# Same IDs as the Go image. The existing PVC and the pod's fsGroup stay valid.
arg UID=2357
arg GID=2357

# knot-server links against libc only and never shells out to git.
# ca-certificates is for its outbound HTTPS to PLC and to users' PDSes.
run apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

run groupadd -g $GID -f knot && useradd -u $UID -g $GID -d /data -M knot
run mkdir -p /data/repos /data/lfs && chown -R $UID:$GID /data
copy --from=builder /src/target/release/knot-server /usr/bin/knot-server
copy --from=builder /src/target/release/knot-migrate /usr/bin/knot-migrate

# Numeric, so runAsNonRoot can verify it without resolving a name.
user ${UID}:${GID}
entrypoint ["/usr/bin/knot-server"]
