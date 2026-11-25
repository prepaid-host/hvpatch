# Unattended pipeline (Kubernetes)

`builder/run.sh` builds one kernel on one host with Docker or Podman. For
a repository that follows Proxmox's kernel releases on its own, the same
stages run as a Kubernetes CronJob. The project builds at
<https://mirror.prepaid-host.io/hvpatch/> are made this way.

## What it does

Every 30 minutes one pod runs these stages, each in its own container and
one after the other (`builder/pipeline.sh <stage>`):

| Stage | Does | Gets |
| --- | --- | --- |
| `prepare` | updates the repository checkout, fetches the published repository, decides what to build (`builder/plan.sh`) | upload key (read) |
| `fetch` | downloads the shipped kernel packages, records checksums of what Gate A and QEMU read | – |
| `build` | klp-build, Gate A, source bundle (`build.sh`) | checkout read-only, **no keys** |
| `sign` | checks the shipped artifacts, Gate A again, module signature | module key |
| `test` | checks the shipped artifacts, QEMU stage (TCG if there is no `/dev/kvm`) | – |
| `publish` | checks again, signs the manifest (`publish.sh`, ring canary), uploads | manifest key, upload key |

`plan.sh` picks at most one kernel per run: the `NEWEST` releases of each
series in `SERIES` (from the Proxmox repository via apt, so the package
signatures are checked) that have no published level yet, or whose
published level was built from an older catalog. A kernel that failed, or
had nothing to livepatch, at a catalog commit is not tried again until the
catalog changes. Releases missing from `kernels.lock` are built with
`AUTO_LOCK=1` from the commit that released them (logged).

Only one run works on the volume at a time: `prepare` takes a lock that
`publish` releases (or a failing stage). A run started by hand while another
one is active does nothing. A lock older than `LOCK_STALE_MIN` minutes (420)
comes from a killed pod and is taken over. The `run` directory of the volume
holds the lock, so the publish container mounts it writable.

## Trust

- The build stage runs kernel Makefiles and catalog patches. It never sees a
  key, it gets the repository checkout read-only, and the plan and the
  checksums of the shipped artifacts are on a volume it does not mount.
  Sign, test and publish check the shipped artifacts against those
  checksums before they rely on them.
- The manifest key is online in this setup (a Kubernetes secret, mounted
  only into the publish container). Whoever controls the cluster can sign
  for every node that trusts this key. Keep the key offline instead
  (`builder/run.sh` and `publish.sh` on a signing machine) if that is not
  acceptable, or trust such a key on canary nodes only.
- The pod has no service account token. The QEMU stage runs without network
  (`-nic none`).

## Running it

You need: the builder image (`ghcr.io/prepaid-host/hvpatch-builder`, built by
`.github/workflows/builder-image.yml`, pin it by digest), a volume for the
build cache (about 55 GB per kernel tree; `KEEP_TREES` limits it), the two
keys and an SSH key for the repository host, which should accept it only
for `rrsync` on the repository directory.

The manifests of the project's own setup (Fleet, RKE2, Ceph) are in the
`k8s-ph-1` repository of Prepaid-Host (`apps/hvpatch-builder`,
`apps/mirror`); this repository does not depend on them.
