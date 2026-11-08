# Kubernetes manifests

Example manifests for running the knot behind ingress-nginx. The knot is
`knot-server`, the Rust knot that upstream also calls knot 2. It serves HTTP
on 5555 and SSH on 2222 from one process, as a non-root user. There is no
sshd, no SQLite database, and no secure mode. Git is the knot's only database.

Coming from the Go knot? Read
[Migrating from the Go knot](#migrating-from-the-go-knot) before you apply
anything here. The Go knot's manifests are kept in [`golang/`](golang/) for
rollback.

## Layout

    00-namespace.yaml           namespace, baseline until the migration settles
    10-configmap.yaml           knot-server ConfigMap
    30-statefulset.yaml         the knot
    40-services.yaml            HTTP and SSH Services
    50-ingress.yaml             HTTPS Ingress
    ingress-nginx-values.yaml   SSH on port 22 through ingress-nginx
    migrate/rehearse.yaml       knot-migrate --dry-run, Go knot still up
    migrate/migrate.yaml        knot-migrate for real, Go knot stopped
    golang/                     the Go knot's ConfigMap and StatefulSet

## Before applying

Edit `10-configmap.yaml`. Set `KNOT_HOSTNAME`, `KNOT_ADMINS`, and
`KNOT_CONTACT_EMAIL`. Replace `knot.example.com` in `50-ingress.yaml` too.
Point the `image:` fields in `30-statefulset.yaml` and `migrate/` at your
registry.

## Secrets

The knot needs two Secrets.

`knot-master-key` holds the master key. It unseals the key store at
`/data/knot2/sealed-keys`. The key store holds the knot's own signing key and,
after a migration, every repo's signing key. Lose the master key and the knot
can no longer prove it owns its repos. Generate it locally, keep a copy off the
cluster, then create the Secret:

    printf %s "$(openssl rand -base64 32)" > knot-master-key
    kubectl -n knot create secret generic knot-master-key \
      --from-file=KNOT_MASTER_KEY=knot-master-key

`knot-sshd-host-keys` holds the SSH host key. A migrated knot already has this
Secret from the Go knot. The knot uses only `ssh_host_ed25519_key` from it. A
fresh install needs only that key:

    ssh-keygen -q -N '' -C '' -t ed25519 -f ssh_host_ed25519_key
    kubectl -n knot create secret generic knot-sshd-host-keys \
      --from-file=ssh_host_ed25519_key --from-file=ssh_host_ed25519_key.pub

The host key lives in a Secret, not on the PVC, so it is backed up apart from
the volume. The Secret cannot be mounted where the knot reads it. The pod's
`fsGroup` leaves Secret files at mode 0440, and the knot refuses a host key
that is group-readable. The `init-host-key` init container copies it into an
emptyDir at mode 0600 instead. It runs as the knot user and needs no
capabilities.

## Fresh install

    kubectl apply -f 00-namespace.yaml
    # create both Secrets here
    kubectl apply -f 10-configmap.yaml -f 30-statefulset.yaml \
                  -f 40-services.yaml  -f 50-ingress.yaml

Then merge `ingress-nginx-values.yaml` into your ingress-nginx Helm values and
upgrade the release.

A fresh knot creates new repos as `sha1`, per `KNOT_GIT_OBJECT_FORMAT`.
Upstream's default is `sha256`. Pick one before anyone creates a repo. A
`sha256` repo cannot exchange objects with a `sha1` one, such as a GitHub
mirror. Changing it later only affects new repos.

## Register

Admission is closed by default. An admin adds each member before they can
create repos. Register the knot on tangled.org under the first DID in
`KNOT_ADMINS`. A migrated knot keeps its hostname and its `did:web`, so it
needs no new registration.

Check that the knot answers on its public hostname first:

    curl -fsS https://knot.example.com/xrpc/_health
    curl -fsS https://knot.example.com/xrpc/org.tangled.knot.describeKnot
    curl -fsS https://knot.example.com/.well-known/did.json
    ssh-keyscan -t ed25519 knot.example.com

`_health` returns the version. `describeKnot` returns the knot's
`did:web:knot.example.com`, its contact email, and its capabilities.
`did.json` is the knot's DID document. The keyscan fingerprint must match
`ssh-keygen -lf ssh_host_ed25519_key.pub`.

The Go knot answered `/xrpc/sh.tangled.owner`. The Rust knot does not serve
it.

## Migrating from the Go knot

This follows the upstream
[migration guide](https://tangled.org/docs/upgrading/knot-2/). Read that first.
What follows is only what differs on Kubernetes, plus one step the guide
leaves out.

The Go knot's paths map onto the guide's paths like this. The PVC
`data-knot-0` is mounted at `/data` in the migration Jobs. The Go knot mounted
it at `/home/git`.

| Guide | Here |
| --- | --- |
| `/home/git/knotserver.db` | `/data/knotserver.db` |
| repo scan path | `/data/repositories` |
| `/etc/ssh/ssh_host_ed25519_key` | `ssh_host_ed25519_key` in the `knot-sshd-host-keys` Secret |
| `/var/lib/knot` | `/data/knot2` |
| `/etc/knot/knot.env` | the `knot-master-key` Secret |

The Rust knot's state goes on the same PVC as the Go knot's, under
`/data/knot2`. That keeps the StatefulSet's `volumeClaimTemplates` unchanged,
so the StatefulSet updates in place. Those templates are immutable. In copy
mode, the default, the Go knot's data stays where it is for rollback. The
volume needs room for a second copy of every repo.

### Before the day

1. Build and push the `knot:v1.20.0` image. Keep `knot:v1.16.1-alpha` in the
   registry, since rollback uses it.
2. Create the `knot-master-key` Secret as in [Secrets](#secrets). Store the
   key somewhere off the cluster.
3. Edit and apply the new ConfigMap. Set `KNOT_ADMINS` to the Go knot's
   `KNOT_SERVER_OWNER`. Keep the same hostname.

       kubectl apply -f 10-configmap.yaml

   It is named `knot-server`. The Go knot reads the ConfigMap named `knot`,
   which is untouched, so the running knot is unaffected.

### Dress rehearsal

The Go knot keeps serving. The rehearsal Job is pinned to knot-0's node,
because the PVC is ReadWriteOnce and only pods on that node can mount it. It
runs as root, because secure mode left each repo tree owned by a per-owner UID
that only root can read.

    kubectl apply -f migrate/rehearse.yaml
    kubectl -n knot logs -f job/knot-migrate-rehearse

Rehearse until the Job succeeds and the last block reads
`scan path: writable`, `host key algorithm: ssh-ed25519`, and
`master key: KNOT_MASTER_KEY decodes to a usable key`. Check that
`knot owner` is the first DID in `KNOT_ADMINS`.

Check the hostname by hand, because the report does not print it. The
migration seals the knot's identity as `did:web:<KNOT_HOSTNAME>`. A wrong
hostname here cannot be fixed after the real run. `KNOT_HOSTNAME` in the
`knot-server` ConfigMap must equal `KNOT_SERVER_HOSTNAME` in the old `knot`
ConfigMap:

    kubectl -n knot get configmap knot -o jsonpath='{.data.KNOT_SERVER_HOSTNAME}'
    kubectl -n knot get configmap knot-server -o jsonpath='{.data.KNOT_HOSTNAME}'

Check `room to copy` too. If the volume is too small, expand the PVC first. The alternative is
`--consume-source`, which moves the repos instead and leaves nothing to roll
back to. Take a VolumeSnapshot before using it.

To rehearse again:

    kubectl -n knot delete job knot-migrate-rehearse
    kubectl apply -f migrate/rehearse.yaml

### Cutover

Downtime starts here.

1. Stop the Go knot. sshd and the knot shut down cleanly and SQLite
   checkpoints its WAL.

       kubectl -n knot scale statefulset knot --replicas=0
       kubectl -n knot wait --for=delete pod/knot-0 --timeout=120s

   A VolumeSnapshot of `data-knot-0` at this point is cheap insurance.

2. Run the migration. The Job first copies the database to
   `/data/knotserver-cutover.db`, which is step 2 of the guide. Then it runs
   `knot-migrate` and hands `/data/knot2` to the knot user, UID 2357.

       kubectl apply -f migrate/migrate.yaml
       kubectl -n knot logs -f job/knot-migrate

   The Job is anti-affine to any knot pod. If knot-0 is still around, it
   stays Pending rather than run beside a live Go knot.

   Skip the guide's step 4, the sshd port dance. sshd lived inside the Go
   knot's pod and is gone. The `knot-ssh` Service still answers on port 22,
   and its `targetPort: ssh` now resolves to the knot's 2222. Nobody changes a
   git remote.

3. Start the Rust knot. Leave `KNOT_REPO_SIGNING_KEYS` commented out for now.

       kubectl apply -f 30-statefulset.yaml
       kubectl -n knot logs -f knot-0

   Wait for `index ready`, then `listening on`. Downtime ends here.

4. Check it worked as in [Register](#register). Then clone a repo
   anonymously, and push to one you own. The keyscan fingerprint must be the
   one users already have.

   The knot reads SSH keys from each user's PDS on a one-hour lease. When
   someone's push fails with a key error, check that their key record is still
   in their PDS. Re-adding the key in their Tangled settings writes it back.

### Commit to the Rust knot

Until this step, rollback is clean. This step is not in the upstream guide.
It comes from reading the knot's source.

Every migrated repo has a `did:plc`. The Rust knot moves each one onto its own
signing key. To sign that change, it needs each repo's old key, which the Go
knot held. `knot-migrate` writes those keys to
`/data/knot2/repo-signing-keys.json`, but it does not seal them into the key
store. The knot seals them on start, and only when `KNOT_REPO_SIGNING_KEYS`
names the archive. Without it, the log has one error per repo:
`plc reconciler gave up on this repository`, with a hint to set
`repo_signing_keys`. Until then this is expected.

After this step, the repos' DID documents name the Rust knot's key. The Go
knot can no longer sign for them, so going back is no longer clean.

1. Copy the archive off the cluster. It holds every repo's private key in
   plaintext.

       kubectl -n knot exec knot-0 -- cat /data/knot2/repo-signing-keys.json \
         > repo-signing-keys.json

2. Uncomment `KNOT_REPO_SIGNING_KEYS` in `10-configmap.yaml`, apply it, and
   restart. A ConfigMap change does not restart the pod by itself.

       kubectl apply -f 10-configmap.yaml
       kubectl -n knot rollout restart statefulset knot
       kubectl -n knot logs -f knot-0

   Look for `sealed migrated per-repo signing keys` with a count equal to the
   number of repos. Then, per repo, `plc operation accepted` and on a later
   pass `plc document matches the desired account shape`.

3. Comment `KNOT_REPO_SIGNING_KEYS` out again, apply, and restart. Do this
   before deleting the archive. The knot fails to start when the variable
   names a missing file.

       kubectl apply -f 10-configmap.yaml
       kubectl -n knot rollout restart statefulset knot

4. Once knot-0 is Ready, delete the archive from the volume.

       kubectl -n knot exec knot-0 -- rm /data/knot2/repo-signing-keys.json

### Going back in case of emergency

Only clean before [Commit to the Rust knot](#commit-to-the-rust-knot). Anything
pushed to the Rust knot since the cutover is lost.

    kubectl -n knot scale statefulset knot --replicas=0
    kubectl -n knot wait --for=delete pod/knot-0 --timeout=120s
    kubectl apply -f golang/10-configmap.yaml -f golang/30-statefulset.yaml

The Go knot's database and repos are where it left them. Restore
`/data/knotserver-cutover.db` over `/data/knotserver.db` only if something
wrote to the original. The migration never does.

### Cleaning up

Once the migration is settled:

- Switch all four PodSecurity labels in `00-namespace.yaml` to `restricted`.
  The Go knot and the migration Jobs will no longer start.
- Delete the Jobs and the Go knot's ConfigMap:
  `kubectl -n knot delete job knot-migrate knot-migrate-rehearse` and
  `kubectl -n knot delete configmap knot`.
- Reclaim the Go knot's space on the volume: `/data/repositories`,
  `/data/knotserver.db*`, and `/data/knotserver-cutover.*`. Secure mode left
  some of those owned by per-owner UIDs, so the knot user cannot delete them.
  Use a one-off root pod, before the namespace goes restricted.
- The rsa and ecdsa keys in `knot-sshd-host-keys` are unused now. Keep them in
  case of rollback, or drop them after.

## Client addresses behind ingress-nginx

Every request reaches the knot from an ingress-nginx controller pod. The knot
rate-limits HTTP per client address, 50 per second by default. It caps
concurrent SSH operations per address at 4. Behind the controller, all users
share both limits.

For HTTP, uncomment `KNOT_XRPC_TRUSTED_PROXY_HEADER` and
`KNOT_XRPC_TRUSTED_PROXIES` in the ConfigMap. Set the CIDR to the range your
controller pods get their IPs from. The knot honours `X-Forwarded-For` from
those addresses only. With the header set and the list empty, any client that
reaches port 5555 can pick its own address. The knot warns at every start
until both are set.

For SSH, uncomment `KNOT_SSH_PROXY_PROTOCOL_FROM` with the same CIDR. Roll it
out. Then switch the tcp line in `ingress-nginx-values.yaml` to the `::PROXY`
form. Do it in this order. The knot accepts connections without a PROXY header
from those addresses. It does not look for the header from any other address,
so a PROXY header from an untrusted peer breaks that connection.

In both cases nginx only sees real client addresses when the controller
Service has `externalTrafficPolicy: Local`.
