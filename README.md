# knot-k8s

Docker image and Kubernetes manifests to run a [Tangled](https://tangled.org)
knot on Debian.

A knot serves repositories over HTTPS and SSH. This repo packages the upstream
`knot` binary into a single container. The container runs both the knot server
and an sshd, supervised by runit.

## What is in the image

The build is two stages. The builder clones
[`@tangled.org/core`](https://tangled.org/@tangled.org/core) at the requested
tag and compiles `./cmd/knot` with cgo enabled. The runtime stage is
`debian:trixie-slim` with git, openssh-server, and runit.

`/usr/local/sbin/boot` is PID 1. It snapshots a few env vars to
`/run/knot/env`, then hands off to `runsvdir`. On `SIGTERM` it brings the
services down with `sv -w 10` before exiting.

Two services live under `/etc/knot/sv`:

- `knotserver` runs `knot server` as the unprivileged `git` user via `chpst`.
- `sshd` generates any missing host keys, then runs `sshd -e -D`.

sshd is configured to accept only the `git` user. Public keys are resolved at
login time by `AuthorizedKeysCommand`, which calls `/usr/local/bin/keys-wrapper`
as `nobody`. That wrapper asks the knot's internal API for the current key set.
Password authentication is off.

The image exposes 5555 (HTTP) and 22 (SSH). It creates the `git` user and group
with UID and GID 2357.

## Build

    make build

`TAG` selects the upstream release and doubles as the image tag. `IMAGE`
selects the image name.

    make build TAG=v1.16.1-alpha IMAGE=knot

## Configuration

Everything is environment variables, read by the knot binary itself.

| Variable | Purpose |
| --- | --- |
| `KNOT_SERVER_HOSTNAME` | Public DNS name. Must match the TLS certificate. |
| `KNOT_SERVER_OWNER` | DID of the account that owns the knot. |
| `APPVIEW_ENDPOINT` | Appview to register against, e.g. `https://tangled.org`. |
| `KNOT_SERVER_LISTEN_ADDR` | Public HTTP bind address. Defaults to `0.0.0.0:5555`. |
| `KNOT_SERVER_INTERNAL_LISTEN_ADDR` | Internal API bind address. Defaults to `localhost:5444`. |
| `KNOT_REPO_SCAN_PATH` | Where bare repos live. Image default is `/home/git/repositories`. |
| `KNOT_SERVER_DB_PATH` | SQLite database path. |
| `KNOT_SERVER_SECURE_MODE` | Turns on repository isolation. See below. |

The internal API on 5444 is unauthenticated. Keep it on loopback. Only sshd and
the git hooks inside the container need to reach it.

sshd strips the environment before running `AuthorizedKeysCommand`. That is why
`boot` writes `/run/knot/env`. `keys-wrapper` sources that file to recover the
listen address, the scan path, and the secure-mode setting.

## Secure mode

With `KNOT_SERVER_SECURE_MODE=true`, knot runs each git subprocess under a
per-owner virtual UID and a Landlock sandbox. This needs a kernel with Landlock
available.

Two pieces make it work in a container:

- The Dockerfile runs `setcap cap_setuid,cap_setgid,cap_chown+eip` on
  `/usr/bin/knot`. The server runs as `git`, so it needs those capabilities to
  drop into a virtual UID.
- `keys-wrapper` passes `-secure-mode` to `knot keys`. That flag is what makes
  the emitted `authorized_keys` forced command put `knot guard` into sandboxed
  mode. Without it the server enforces isolation but SSH-side git commands do
  not.

File capabilities are ignored when `no_new_privs` is set. On Kubernetes that
means `allowPrivilegeEscalation` must stay `true`. See
[`manifests/30-statefulset.yaml`](manifests/30-statefulset.yaml) for the full
set of constraints.

## Kubernetes

[`manifests/`](manifests/) has a working example: a single-replica StatefulSet
on a PVC, behind ingress-nginx, with SSH exposed through the controller's TCP
services map. Read [`manifests/README.md`](manifests/README.md) for the setup
order.

Three things there are easy to get wrong.

- Host keys belong in a Secret, not on the PVC. Otherwise every reschedule
  changes the host key.
- SSH must answer on port 22 of the same hostname as the Ingress. Tangled clone
  URLs are scp-style and cannot carry a port.
- The namespace is `baseline`, not `restricted`. sshd needs root to bind 22 and
  to run `AuthorizedKeysCommand` as `nobody`.

## Layout

    Dockerfile              two-stage build
    Makefile                build targets
    manifests/              Kubernetes example
    rootfs-debian/          files copied into the image
      usr/local/sbin/boot   PID 1, runit supervisor
      usr/local/bin/keys-wrapper
      etc/knot/sv/          runit service definitions
      etc/ssh/sshd_config.d/

## License

MIT. See [LICENSE](LICENSE).
