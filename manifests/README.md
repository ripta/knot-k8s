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

All three key types must be present. The run script generates any that are
missing, and the Secret mount is read-only.

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

## Still outstanding

`KNOT_SERVER_SECURE_MODE=true` in the ConfigMap only reaches the server. The
`knot keys` command needs its own `-secure-mode` flag, which makes it emit
`-secure-mode` into the forced command in `authorized_keys`. That flag is what
puts `knot guard` into sandboxed mode on the SSH side.

`usr/local/bin/keys-wrapper` does not pass it, and `usr/local/sbin/boot`
snapshots only `KNOT_SERVER_INTERNAL_LISTEN_ADDR` and `KNOT_REPO_SCAN_PATH` to
`/run/knot/env`. Until that is wired up, the server enforces isolation but git
commands arriving over SSH run unsandboxed.
