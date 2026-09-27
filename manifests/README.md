# Kubernetes manifests

Example manifests for running this image with secure mode on, behind
ingress-nginx. Assumes Landlock is available on the node kernel.

## Before applying

Edit `10-configmap.yaml` and set `KNOT_SERVER_HOSTNAME` and
`KNOT_SERVER_OWNER`. Replace `knot.example.com` in `50-ingress.yaml` too.
Point the `image:` fields in `30-statefulset.yaml` at your registry.

## Generate the SSH host keys

Host keys go in a Secret, not on the PVC. The sshd run script generates them
into the container's writable layer, which is discarded on every restart.
Every reschedule would change the host key and every user would get
`REMOTE HOST IDENTIFICATION HAS CHANGED`.

All three key types must be present. The `init-host-keys` init container
copies exactly those six files and fails if any is missing.

The Secret is not mounted at `/etc/ssh/keys` directly. Kubernetes applies
`fsGroup` to Secret volumes too, so the keys would end up mode 0440. sshd
rejects group-readable host keys with `UNPROTECTED PRIVATE KEY FILE` and exits.
The pod needs `fsGroup` for secure mode, so the init container copies the keys
into an emptyDir as `root:root` with mode 0600 instead.

With secure mode off, there is a simpler setup. Only use it with secure mode
off, because secure mode relies on `fsGroup`. Drop `fsGroup` and mount the
Secret at `/etc/ssh/keys` directly with `defaultMode: 0400`. sshd accepts the
keys as mounted. Drop `init-isolation` too, since its steps are for secure
mode. Replace it with a root init container (`runAsUser: 0`, `CHOWN` added)
that gives the data volume to git:

    mkdir -p /home/git/repositories
    chown 2357:2357 /home/git /home/git/repositories

    ssh-keygen -q -N '' -C '' -t rsa -b 4096 -f ssh_host_rsa_key
    ssh-keygen -q -N '' -C '' -t ecdsa      -f ssh_host_ecdsa_key
    ssh-keygen -q -N '' -C '' -t ed25519    -f ssh_host_ed25519_key

    kubectl -n knot create secret generic knot-sshd-host-keys \
      --from-file=ssh_host_rsa_key     --from-file=ssh_host_rsa_key.pub \
      --from-file=ssh_host_ecdsa_key   --from-file=ssh_host_ecdsa_key.pub \
      --from-file=ssh_host_ed25519_key --from-file=ssh_host_ed25519_key.pub

## Apply

    kubectl apply -f 00-namespace.yaml
    # create the host key Secret here
    kubectl apply -f 10-configmap.yaml -f 30-statefulset.yaml \
                  -f 40-services.yaml  -f 50-ingress.yaml

Then merge `ingress-nginx-values.yaml` into your ingress-nginx Helm values and
upgrade the release.

## Register

The appview verifies the knot by reaching `KNOT_SERVER_HOSTNAME` over HTTPS.
Ingress and certificate must be live first. Then hit verify on
`/settings/knots`.

The appview calls `GET https://<hostname>/xrpc/sh.tangled.owner`. Check that
it answers with your DID before you register:

    curl -fsS https://knot.example.com/xrpc/sh.tangled.owner
    # {"owner":"did:plc:..."}

Verification may not be immediate. It can take several minutes before the
appview calls this endpoint. The settings page updates only after that call succeeds.

## How secure mode reaches SSH

`KNOT_SERVER_SECURE_MODE=true` in the ConfigMap has to reach two places, not
one. The server picks it up from the environment. The SSH side does not.

`knot keys` needs its own `-secure-mode` flag. That flag makes it emit
`-secure-mode` into the forced command in `authorized_keys`, which is what puts
`knot guard` into sandboxed mode.

`usr/local/sbin/boot` snapshots the setting to `/run/knot/env`, and
`usr/local/bin/keys-wrapper` sources that file and passes the flag through. Set
the ConfigMap value and both paths are covered.
