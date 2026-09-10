# hyperswitch-build

Builds the Hyperswitch **router** container image used by the mergesk self-hosted stack: the official upstream source at the
tag in `VERSION` plus the patches in `patches/`, built with the **unmodified upstream `Dockerfile`** (`--no-default-features --features release
--features v1`, `BINARY=router`) plus the build arg `EXTRA_FEATURES=--features redis-rs` (the Dockerfile default `""` does not compile:
`redis_interface` needs exactly one backend, and the official `v1.126.0` binary was built with `redis-rs` — crate `redis-1.2.0`, no `fred` symbols),
pushed to GHCR as one manifest under two tags:

```
<IMAGE>:<VERSION>                        e.g. ghcr.io/vutrungkien/hyperswitch-router:v1.126.0            (deployed by Helm)
<IMAGE>:<VERSION>-mergesk.<PATCHLEVEL>   e.g. ghcr.io/vutrungkien/hyperswitch-router:v1.126.0-mergesk.1  (immutable provenance)
```

Why the deployed tag is the plain upstream tag: the Helm chart (`hyperswitch-app` 1.2.1) uses `services.router.version` not only
for the router image but also for the DB-migration Job tarball (`github.com/juspay/hyperswitch/archive/refs/tags/<version>.tar.gz`,
`templates/db/hyperswitch-db-job.yaml`) and the Superposition seed URL (`templates/_helpers.tpl` `superpositionFallback.url`).
A tag that does not exist upstream breaks both, so the values keep `version: v1.126.0` and only switch registry + repository.
The OCI labels `mergesk.upstream` / `mergesk.patchlevel` say which build a node runs (`crictl inspecti`).

Files: `IMAGE` (registry/repository, must be `ghcr.io/<repo owner>/hyperswitch-router`), `VERSION` (upstream tag),
`PATCHLEVEL` (integer, bump whenever patch content changes for the same VERSION), `patches/`, `scripts/apply.sh`.
No secrets live here. The image contains no configuration; the Helm chart injects config exactly as with the official image.

## Patches

| File | What | Why |
|---|---|---|
| `patches/0001-paypal-payer.patch` | PayPal connector sends the `payer` object (e-mail, name, phone, billing address) when creating an order (`POST /v2/checkout/orders`) in the redirect and SDK flows. Off per connector with connector metadata `{"send_payer": false}`. | PayPal prefills the login e-mail and shortens the guest "Debit or Credit Card" form to card number / expiry / CSC. Upstream does not send `payer`; PayPal refuses `PATCH /payer`. |

Every patch must apply with `git apply --check` on a clean checkout of `VERSION`; `scripts/apply.sh <dir>` applies them all.

## Build (GitHub Actions)

- Push to `main` touching `VERSION`, `PATCHLEVEL`, `IMAGE`, `patches/`, `scripts/` or the workflow → job `router` builds and pushes the router image.
- `Actions → build-hyperswitch → Run workflow` with `build_scheduler=true` also builds `hyperswitch-consumer` and `hyperswitch-producer` from the same source (only needed when a patch touches scheduler code paths).
- First build takes 1-2 h on the free runner (full Rust release build); later builds reuse the GitHub Actions layer cache.
- After the first push, make the package **public** (GitHub → Packages → `hyperswitch-router` → Package settings → Change visibility → Public) so the cluster pulls without a pull secret.

## Upgrade Hyperswitch (new upstream tag)

1. Set `VERSION` to the new upstream tag, reset `PATCHLEVEL` to `1`.
2. Locally: `git clone --depth 1 -b <tag> https://github.com/juspay/hyperswitch /tmp/hs && bash scripts/apply.sh /tmp/hs` — fix the patch if it no longer applies (rebase, keep the same intent).
3. Commit + push → build → in mergesk set `hyperswitch-app.services.router.version` to the same tag → `verify-render` → snapshot + `install.sh` per `docs/runbooks/upgrade.md` / `docs/runbooks/router-image.md`.

## Patch-level bump (same upstream tag, patch content changed)

Bump `PATCHLEVEL`, push → the build re-points `<IMAGE>:<VERSION>` to the new digest. The pod spec does not change, so
`infra/scripts/install.sh` (via `router-image.sh sync`) pulls the tag again on the node and restarts the router when the
running digest differs — see `docs/runbooks/router-image.md`.

## Rollback

Set `services.router` in the Helm values back to the official image (`imageRegistry: docker.juspay.io`, `image: juspaydotin/hyperswitch-router`, same `version`) and run `install.sh`. Data and config are unchanged by the patch.

## Local check of a patch (optional)

The connector crate needs the same features the router release build enables for it (`payouts`, `frm`; `worldpayxml` does not compile without `payouts`):

```
docker run --rm -v "$PWD/upstream:/src" -v hs-cargo-registry:/usr/local/cargo/registry -w /src rust:trixie \
  bash -c "apt-get update -qq && apt-get install -y -qq libpq-dev libssl-dev pkg-config protobuf-compiler >/dev/null; \
           cargo test -p hyperswitch_connectors --features 'v1 payouts frm' payer_tests"
```
