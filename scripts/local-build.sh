#!/usr/bin/env bash
# scripts/local-build.sh <patched-upstream-dir> [build|image|push|all] - the build path of this repo (mergesk ADR-0015: the free GitHub
# runner has 16 GB RAM, the router crate needs more):
#   build : cargo release build of the router in a memory-capped rust:trixie container (scripts/container-build.sh = same cargo command
#           as the upstream Dockerfile, EXTRA_FEATURES from ./EXTRA_FEATURES) -> named volume $HS_TARGET_VOLUME (resumable)
#   image : export binary + config from the volume to ./out/router/... and run the UNMODIFIED upstream Dockerfile with
#           --build-context builder=./out (its builder stage is replaced by that directory, the runtime stage is upstream's as is);
#           tags IMAGE:VERSION and IMAGE:VERSION-mergesk.PATCHLEVEL, OCI labels mergesk.upstream / mergesk.patchlevel
#   push  : docker login with the classic PAT (line "ghcr=ghp_..." in $GHCR_TOKEN_FILE, scope write:packages), push both tags, logout
# Idempotent: rerunning resumes cargo (fingerprints), re-exports and re-pushes the same digest. Git Bash on Windows (Docker Desktop) or Linux.
# Env: HS_BUILD_MEMORY (24g) HS_BUILD_CPUS (8) HS_BUILD_JOBS (=CPUS) HS_BUILD_DETACH=1 (return at once; then: docker wait hs-local-build)
#      HS_CARGO_REGISTRY_VOLUME (hs-cargo-registry) HS_TARGET_VOLUME (hs-target) HS_SOURCE_URL (repo URL for the OCI source label)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: local-build.sh <patched-upstream-dir> [build|image|push|all]}"
STEP="${2:-all}"
case "$STEP" in build|image|push|all) ;; *) echo "unknown step: $STEP (build|image|push|all)"; exit 1 ;; esac
[ -d "$SRC" ] || { echo "FAIL not a directory: $SRC"; exit 1; }
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }   # C:/... form for Docker Desktop
export MSYS_NO_PATHCONV=1

IMAGE=$(tr -d ' \r\n' < "$HERE/IMAGE"); VERSION=$(tr -d ' \r\n' < "$HERE/VERSION"); PATCHLEVEL=$(tr -d ' \r\n' < "$HERE/PATCHLEVEL")
EXTRA_FEATURES=$(tr -d '\r\n' < "$HERE/EXTRA_FEATURES")
MEM="${HS_BUILD_MEMORY:-24g}"; CPUS="${HS_BUILD_CPUS:-8}"; JOBS="${HS_BUILD_JOBS:-$CPUS}"
REG_VOL="${HS_CARGO_REGISTRY_VOLUME:-hs-cargo-registry}"; TGT_VOL="${HS_TARGET_VOLUME:-hs-target}"
OWNER=$(echo "$IMAGE" | cut -d/ -f2); REGISTRY=${IMAGE%%/*}
SOURCE_URL="${HS_SOURCE_URL:-https://github.com/$OWNER/hyperswitch-build}"
OUT="$HERE/out"; CTX="$OUT/ctx"
TAG_UP="$IMAGE:$VERSION"; TAG_PL="$IMAGE:$VERSION-mergesk.$PATCHLEVEL"
SRC_W=$(winpath "$(cd "$SRC" && pwd)"); HERE_W=$(winpath "$HERE"); OUT_W=$(winpath "$OUT")

# sanity: upstream checkout is at VERSION and carries every patch (each patch must apply in reverse)
git -C "$SRC" tag --points-at HEAD | grep -qx "$VERSION" || { echo "FAIL $SRC is not at upstream tag $VERSION"; exit 1; }
for p in "$HERE"/patches/*.patch; do
  git -C "$SRC" -c core.autocrlf=false apply --check -R "$p" >/dev/null 2>&1 || { echo "FAIL patch not applied in $SRC: $(basename "$p") (run scripts/apply.sh)"; exit 1; }
done
echo "source $SRC_W = $VERSION + $(ls "$HERE"/patches/*.patch | wc -l | tr -d ' ') patch(es) -> $TAG_UP + $TAG_PL"

build() {
  docker rm -f hs-local-build >/dev/null 2>&1 || true
  echo "build: rust:trixie --cpus=$CPUS --memory=$MEM jobs=$JOBS EXTRA_FEATURES=$EXTRA_FEATURES"
  local detach=(); [ "${HS_BUILD_DETACH:-0}" = 1 ] && detach=(-d)
  docker run "${detach[@]}" --name hs-local-build --cpus="$CPUS" --memory="$MEM" --memory-swap="$MEM" \
    -v "$SRC_W:/src:ro" -v "$REG_VOL:/usr/local/cargo/registry" -v "$TGT_VOL:/target" -v "$HERE_W/scripts:/build-scripts:ro" \
    -e CARGO_INCREMENTAL=0 -e CARGO_NET_RETRY=10 -e RUSTUP_MAX_RETRIES=10 -e RUST_BACKTRACE=short \
    -e CARGO_BUILD_JOBS="$JOBS" -e CARGO_TARGET_DIR=/target -e EXTRA_FEATURES="$EXTRA_FEATURES" \
    rust:trixie bash -c 'tr -d "\r" < /build-scripts/container-build.sh > /tmp/cb.sh && bash /tmp/cb.sh'
  if [ "${HS_BUILD_DETACH:-0}" = 1 ]; then echo "detached: docker wait hs-local-build; docker logs hs-local-build | grep RESULT"; exit 0; fi
  docker rm hs-local-build >/dev/null
}

image() {
  rm -rf "$OUT"; mkdir -p "$OUT/router/target/release" "$OUT/router/config" "$CTX"
  docker run --rm -v "$TGT_VOL:/target:ro" -v "$OUT_W:/out" debian:trixie-slim \
    sh -c 'test -f /target/release/router || { echo "FAIL no /target/release/router in the volume (run build)"; exit 1; }; cp /target/release/router /out/router/target/release/router'
  cp "$SRC/config/payment_required_fields_v2.toml" "$OUT/router/config/"
  echo "exported binary: $(stat -c %s "$OUT/router/target/release/router" 2>/dev/null || wc -c < "$OUT/router/target/release/router") bytes"
  docker buildx build --load --platform linux/amd64 --provenance=false \
    -f "$SRC_W/Dockerfile" --build-context "builder=$OUT_W" --build-arg BINARY=router \
    --label "org.opencontainers.image.source=$SOURCE_URL" \
    --label "org.opencontainers.image.description=Hyperswitch router $VERSION + mergesk patches (patchlevel $PATCHLEVEL)" \
    --label "org.opencontainers.image.version=$VERSION-mergesk.$PATCHLEVEL" \
    --label "mergesk.upstream=$VERSION" --label "mergesk.patchlevel=$PATCHLEVEL" \
    -t "$TAG_UP" -t "$TAG_PL" "$(winpath "$CTX")"
  docker inspect --format 'image {{.Id}} labels: upstream={{index .Config.Labels "mergesk.upstream"}} patchlevel={{index .Config.Labels "mergesk.patchlevel"}} user={{.Config.User}} cmd={{.Config.Cmd}}' "$TAG_UP"
  docker run --rm --entrypoint /local/bin/router "$TAG_UP" --version 2>/dev/null || true
}

push() {
  local f="${GHCR_TOKEN_FILE:?set GHCR_TOKEN_FILE=<file with a line ghcr=ghp_... (classic PAT, scope write:packages)>}"
  local tok; tok=$(grep -m1 '^ghcr=' "$f" | cut -d= -f2- | tr -d '\r\n ')
  [ -n "$tok" ] || { echo "FAIL no ghcr= line in $f"; exit 1; }
  printf '%s' "$tok" | docker login "$REGISTRY" -u "$OWNER" --password-stdin >/dev/null
  trap 'docker logout "$REGISTRY" >/dev/null 2>&1 || true' EXIT
  docker push "$TAG_UP" | tail -1
  docker push "$TAG_PL" | tail -1
  local d1 d2
  d1=$(docker buildx imagetools inspect "$TAG_UP" --format '{{.Manifest.Digest}}')
  d2=$(docker buildx imagetools inspect "$TAG_PL" --format '{{.Manifest.Digest}}')
  echo "pushed $TAG_UP $d1"; echo "pushed $TAG_PL $d2"
  [ "$d1" = "$d2" ] || { echo "FAIL the two tags do not share a digest"; exit 1; }
}

case "$STEP" in
  build) build ;;
  image) image ;;
  push)  push ;;
  all)   build; image; push ;;
esac
echo "OK $STEP"
