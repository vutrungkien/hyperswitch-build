# hyperswitch-build

Builds the Hyperswitch **router** container image used by the mergesk self-hosted stack: the official upstream source at the
tag in `VERSION` plus the patches in `patches/`, built with the **unmodified upstream `Dockerfile`** (`--no-default-features --features release
--features v1`, `BINARY=router`) plus the build arg `EXTRA_FEATURES` = `--features redis-rs` (the Dockerfile default `""` does not compile:
`redis_interface` needs exactly one backend, and the official `v1.126.0` binary was built with `redis-rs` — crate `redis-1.2.0`, no `fred` symbols)
followed by cargo `--config` overrides of the release profile (see "Build" below),
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
`PATCHLEVEL` (integer, bump whenever patch content changes for the same VERSION), `EXTRA_FEATURES` (cargo args appended by the
Dockerfile, one line), `patches/`, `scripts/apply.sh` (apply patches), `scripts/local-build.sh` + `scripts/container-build.sh` (build,
image, push), `scripts/free-runner-disk.sh` (CI only).
No secrets live here. The image contains no configuration; the Helm chart injects config exactly as with the official image.

## Patches

| File | What | Why |
|---|---|---|
| `patches/0001-paypal-payer.patch` | PayPal connector sends the `payer` object (e-mail, name, phone, billing address) when creating an order (`POST /v2/checkout/orders`) in the redirect and SDK flows. Off per connector with connector metadata `{"send_payer": false}`. | PayPal prefills the login e-mail and shortens the guest "Debit or Credit Card" form to card number / expiry / CSC. Upstream does not send `payer`; PayPal refuses `PATCH /payer`. |
| `patches/0002-paypal-shipping-preference.patch` | The PayPal JS SDK order (`PostSessionTokens`) sends `experience_context.shipping_preference = SET_PROVIDED_ADDRESS` when the shipping address actually serialized has a postal code and a city, instead of the hard-coded `GET_FROM_FILE`. | PayPal otherwise asks the buyer for a shipping address of its own, which can differ from the merchant order and voids Seller Protection. The condition mirrors what PayPal validates (422 `MISSING_SHIPPING_ADDRESS` / `POSTAL_CODE_REQUIRED` / `CITY_REQUIRED`, measured on the sandbox 2026-09-12); a state (`admin_area_1`) is not required. |
| `patches/0003-paypal-shipping-address-quality.patch` | The PayPal address object (`shipping.address` of every PayPal flow and `billing_address` of the card flow, one shared struct) carries the state as `admin_area_1`, trimmed, cut at 300 characters and left out when blank; `shipping.name.full_name` is first name + last name (single blanks, whichever part exists) instead of the first name only. | A real order showed the recipient as `huhu` for the buyer `huhu hihi` and an address without its state: PayPal's Seller Protection is tied to shipping to the address on the transaction. PayPal accepts any `admin_area_1` text (`TX`, `texas`, `ZZ`, `Ho Chi Minh`, empty: all 200 on the sandbox, 2026-09-12). |

Every patch must apply with `git apply --check` on a clean checkout of `VERSION`; `scripts/apply.sh <dir>` applies them all.
Every patch must also reverse-apply on the fully patched tree (`scripts/local-build.sh` refuses to build otherwise), so a patch never edits a line another patch added:
new code and its test module go next to what they change (not at the end of the file), and a test that builds a struct literal of a type a later patch may extend ends it with
`..Default::default()` (patch 0002's test helper, changed for exactly that reason when 0003 added `Address.admin_area_1`).

## Build: `scripts/local-build.sh` (not the free GitHub runner)

The free `ubuntu-latest` runner of a public repo has 4 vCPU / 16 GB RAM. The `router` crate alone needs more than 14 GB during codegen,
whatever the LTO / codegen-units settings (measured 2026-09-10 in a 14 GiB-capped container: `rustc --crate-name router` OOM-killed at
13.6 GB while still growing; run 34480081707 died with "The runner has received a shutdown signal"; upstream `docs/try_local_system.md`:
"up to 24GB"). Decision (mergesk ADR-0015):

- `push` to `main` runs only `patch-check` (every patch applies on a clean checkout of `VERSION`, scripts parse). No image is built in CI.
- The image is built where the build container can get >= 24 GB (Docker Desktop on Windows: `%USERPROFILE%\.wslconfig` with `memory=26GB`):

  ```
  git clone --depth 1 -b "$(cat VERSION)" https://github.com/juspay/hyperswitch /path/hs && bash scripts/apply.sh /path/hs
  GHCR_TOKEN_FILE=/path/github.txt bash scripts/local-build.sh /path/hs all       # build (~1 h) + image + push
  ```

  - `build`: `scripts/container-build.sh` in `rust:trixie` with `--memory=24g --cpus=8`: the same cargo command as the upstream
    Dockerfile, `EXTRA_FEATURES` from the file of that name, cargo caches in the named volumes `hs-cargo-registry` / `hs-target`
    (resumable), memory sampler in `/target/measure.log`, `RESULT` lines with peak RSS / duration / binary size.
    Measured 2026-09-10 (v1.126.0, 8 jobs): 38 min, `rustc --crate-name router` peaks at 24.1 GB RSS, binary 430 MB, `target/release`
    8.7 GB — so 24g is the minimum, not a comfortable default. `HS_BUILD_DETACH=1` returns at once (`docker wait hs-local-build`).
    The `router_env` build script (vergen) watches `/router/.git/`: never run git commands that write into the build tree's `.git`
    (even `git diff` refreshes the index) or the whole workspace rebuilds; the script reads git info from `/src` with `GIT_OPTIONAL_LOCKS=0`.
  - `image`: exports `router` + `config/payment_required_fields_v2.toml` to `./out/router/...` and runs the **unmodified upstream
    `Dockerfile`** with `--build-context builder=./out`: BuildKit replaces the builder stage by that directory, the runtime stage
    (debian:trixie, user `app`, `RUST_MIN_STACK`, `CMD`) is upstream's. Tags `IMAGE:VERSION` + `IMAGE:VERSION-mergesk.PATCHLEVEL`,
    labels `org.opencontainers.image.*`, `mergesk.upstream`, `mergesk.patchlevel`.
  - `push`: `docker login` with the line `ghcr=ghp_...` of `$GHCR_TOKEN_FILE` (classic PAT, scope `write:packages`; GHCR refuses
    fine-grained PATs: `permission_denied: token does not match expected scopes`), pushes both tags, checks they share one digest, logs out.
- `workflow_dispatch` with a `runner` label that has >= 24 GB RAM still builds in CI with the same Dockerfile and `EXTRA_FEATURES`
  (`build_scheduler=true` adds `hyperswitch-consumer` / `hyperswitch-producer`). No GHA layer cache: the `RUN cargo build` layer
  comes after `COPY . .`, is invalidated by every patch change and exceeds the 10 GB cache limit.
- `EXTRA_FEATURES` = `--features redis-rs` (required, see top) + cargo `--config profile.release.lto="thin" --config
  profile.release.codegen-units=16` (upstream: fat LTO, 1 unit). The Dockerfile expands `${EXTRA_FEATURES}` unquoted on the cargo
  command line, so the overrides ride along without touching the Dockerfile; `--config` has the highest precedence. Same source and
  features as the official image, only the optimisation profile differs (4x faster build, far less memory).
- After the first push, make the package **public** (GitHub → Packages → `hyperswitch-router` → Package settings → Change visibility → Public) so the cluster pulls without a pull secret.

## Upgrade Hyperswitch (new upstream tag)

1. Set `VERSION` to the new upstream tag, reset `PATCHLEVEL` to `1`.
2. Locally: `git clone --depth 1 -b <tag> https://github.com/juspay/hyperswitch /tmp/hs && bash scripts/apply.sh /tmp/hs` — fix the patch if it no longer applies (rebase, keep the same intent).
3. Commit + push (`patch-check`) → `scripts/local-build.sh <clone> all` → in mergesk set `hyperswitch-app.services.router.version` to the same tag → `verify-render` → snapshot + `install.sh` per `docs/runbooks/upgrade.md` / `docs/runbooks/router-image.md`.

## Patch-level bump (same upstream tag, patch content changed)

Bump `PATCHLEVEL`, push (`patch-check`), run `scripts/local-build.sh <clone> all` → `<IMAGE>:<VERSION>` points to the new digest. The pod spec does not change, so
`infra/scripts/install.sh` (via `router-image.sh sync`) pulls the tag again on the node and restarts the router when the
running digest differs — see `docs/runbooks/router-image.md`.

## Rollback

Set `services.router` in the Helm values back to the official image (`imageRegistry: docker.juspay.io`, `image: juspaydotin/hyperswitch-router`, same `version`) and run `install.sh`. Data and config are unchanged by the patch.

## Local check of a patch (optional)

The connector crate needs the same features the router release build enables for it (`payouts`, `frm`; `worldpayxml` does not compile without `payouts`). `MSYS_NO_PATHCONV=1` stops Git Bash on Windows from rewriting `-w /src` into `C:/Program Files/Git/src`; elsewhere it is ignored:

```
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD/upstream:/src" -v hs-cargo-registry:/usr/local/cargo/registry -w /src rust:trixie \
  bash -c "apt-get update -qq && apt-get install -y -qq libpq-dev libssl-dev pkg-config protobuf-compiler >/dev/null; \
           cargo test -p hyperswitch_connectors --features 'v1 payouts frm' paypal::transformers"
```
