# knot-k8s

Docker image and Kubernetes manifests to run a [Tangled](https://tangled.org)
knot on Debian.

A knot serves repositories over HTTPS and SSH. This repo packages upstream's
Rust knot, `knot-server`, into a single container. Upstream also calls it
knot 2. One process serves HTTP on 5555 and SSH on 2222. There is no sshd, no
unix `git` account, and no SQLite database. Git is the knot's only database.

The Go knot is deprecated upstream. Its last release is `v1.16.1-alpha`.
Moving off it takes a one-time offline migration. Changing the image tag alone
does not migrate anything. See
[Migrating from the Go knot](manifests/README.md#migrating-from-the-go-knot).

## What is in the image

The build is two stages. The builder clones
[upstream core](https://tangled.org/did:plc:j5hmlfdrwkvtxm7cjmu7j2is) at the
requested tag. It builds `knot-server` and `knot-migrate` with cargo. The
runtime stage is `debian:trixie-slim` with `ca-certificates` only. The knot
never shells out to git.

`knot-server` is the entrypoint. It runs as the `knot` user, UID and GID 2357.
Those are the IDs the Go image's `git` user had, so an existing volume keeps
its ownership. `knot-migrate` is in the image too, for the migration.

The image exposes 5555 (HTTP) and 2222 (SSH).

## Build

    make build

`TAG` selects the upstream release and doubles as the image tag. `IMAGE`
selects the image name.

    make build TAG=v1.20.0 IMAGE=knot

## Configuration

Everything is environment variables, read by `knot-server` itself. The
[config reference](https://tangled.org/docs/reference/knot-config/) lists all
of them. These are the ones the manifests set.

| Variable | Purpose |
| --- | --- |
| `KNOT_HOSTNAME` | Public DNS name. The knot's identity is `did:web:<hostname>`. |
| `KNOT_ADMINS` | Comma-separated admin DIDs. The first is the knot owner. |
| `KNOT_CONTACT_EMAIL` | Required. Served by `describeKnot`. |
| `KNOT_PLC_DIRECTORY` | PLC directory, e.g. `https://plc.directory`. |
| `KNOT_MASTER_KEY_ENV` | Name of the variable holding the master key. |
| `KNOT_MASTER_KEY` | Base64 master key, from a Secret. Unseals the key store. |
| `KNOT_LISTEN_ADDR` | HTTP bind address. |
| `KNOT_SSH_LISTEN_ADDR` | SSH bind address. |
| `KNOT_SCAN_PATH` | Where repos live. Must exist and be writable. |
| `KNOT_LFS_STORE_PATH` | LFS store. Must exist, be writable, and sit outside the scan path. |
| `KNOT_SEALED_KEY_FILE` | Sealed key store. Created on first start. |
| `KNOT_SSH_HOST_KEY_FILE` | SSH host key. Must be mode 0600. Generated if absent. |
| `KNOT_GIT_OBJECT_FORMAT` | `sha1` or `sha256` for new repos. |

The image sets defaults for the paths under `/data`. The manifests override
them to `/data/knot2`, where the migration puts the knot's state.

The knot refuses to load a host key that is group- or other-readable. On
Kubernetes that rules out mounting the key Secret directly. See
[`manifests/README.md`](manifests/README.md#secrets).

## Kubernetes

[`manifests/`](manifests/) has a working example: a single-replica StatefulSet
on a PVC, behind ingress-nginx, with SSH exposed through the controller's TCP
services map. Read [`manifests/README.md`](manifests/README.md) for the setup
order and the migration.

Things there that are easy to get wrong:

- SSH must answer on port 22 of the same hostname as the Ingress. Tangled clone
  URLs are scp-style and cannot carry a port. The `knot-ssh` Service maps 22
  onto the knot's 2222.
- The master key and the sealed key store are a pair. Back up the master key
  off the cluster. Without it the knot cannot prove it owns its repos.
- A migration is not finished when the knot starts. The per-repo signing keys
  need one more start with `KNOT_REPO_SIGNING_KEYS` set. The upstream guide
  does not cover this.
- Behind ingress-nginx, every client shares one rate limit until the knot is
  told which addresses are the proxy.

## Layout

    Dockerfile              two-stage build
    Makefile                build targets
    cloudbuild.yaml         Cloud Build image build
    manifests/              Kubernetes example
      migrate/              knot-migrate Jobs
      golang/               the Go knot's manifests, kept for rollback

## License

MIT. See [LICENSE](LICENSE).
