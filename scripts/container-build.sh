#!/usr/bin/env bash
# scripts/container-build.sh - runs INSIDE rust:trixie (started by local-build.sh): the same cargo command as the upstream Dockerfile,
# EXTRA_FEATURES from env expanded unquoted exactly like the Dockerfile, source /src (read-only) copied to /router, target /target
# (named volume, resumable), memory sampler every 10 s -> /target/measure.log, summary lines "RESULT ...". Exit code = cargo's.
set -euo pipefail
: "${EXTRA_FEATURES:?EXTRA_FEATURES must be set (content of ../EXTRA_FEATURES)}"
LOG=/target/measure.log
: > "$LOG"
log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }

apt-get update -qq >/dev/null
apt-get install -y -qq libpq-dev libssl-dev pkg-config protobuf-compiler procps >/dev/null
log "nproc=$(nproc) mem_total_mb=$(free -m | awk '/Mem:/{print $2}') $(cargo --version) $(rustc --version)"
log "EXTRA_FEATURES=$EXTRA_FEATURES jobs=${CARGO_BUILD_JOBS:-default}"

rm -rf /router && mkdir /router
cp -a /src/. /router/
cd /router
# Read-only git info from /src, never from /router: the router_env build script (vergen) declares
# cargo:rerun-if-changed=/router/.git/, so any write into /router/.git (e.g. the index refresh of `git diff`) rebuilds every crate.
log "source: $(GIT_OPTIONAL_LOCKS=0 git -C /src rev-parse --short HEAD 2>/dev/null || echo n/a) tags: $(GIT_OPTIONAL_LOCKS=0 git -C /src tag --points-at HEAD 2>/dev/null | tr '\n' ' ') patched: $(GIT_OPTIONAL_LOCKS=0 git -C /src -c core.autocrlf=false diff --stat 2>/dev/null | tail -1)"

# sampler: used memory, sum of rustc RSS, biggest rustc process with crate name/type
(
  while true; do
    top=$(ps -eo rss,args --no-headers 2>/dev/null | awk '/rustc/ && /--crate-name/ {n="";t=""; for(i=1;i<=NF;i++){ if($i=="--crate-name") n=$(i+1); if($i=="--crate-type") t=$(i+1)}; print $1, n "/" t}' | sort -rn | head -1)
    top=${top:-0 none}
    sum=$(ps -eo rss,args --no-headers 2>/dev/null | awk '/rustc/ {s+=$1} END{print int(s/1024)}')
    echo "$(date -u +%H:%M:%S) used_mb=$(free -m | awk '/Mem:/{print $3}') rustc_sum_mb=${sum:-0} top_rustc_mb=$(( ${top%% *} / 1024 )) top_crate=${top#* }" >> "$LOG"
    sleep 10
  done
) &
SAMPLER=$!

start=$(date +%s)
set +e
# shellcheck disable=SC2086  # EXTRA_FEATURES is word-split on purpose (same as the upstream Dockerfile)
cargo build --release --no-default-features --features release --features v1 ${EXTRA_FEATURES} 2>&1 | tee /target/cargo.log | grep -E "Compiling (router|hyperswitch_connectors) |Finished|^error|signal|Killed|No space"
rc=${PIPESTATUS[0]}
set -e
kill "$SAMPLER" 2>/dev/null || true

log "RESULT cargo_exit=$rc duration_min=$(( ($(date +%s) - start) / 60 ))"
awk '/used_mb=/{ split($2,a,"="); split($3,b,"="); split($4,c,"="); if(a[2]>pu)pu=a[2]; if(b[2]>ps)ps=b[2]; if(c[2]>pt){pt=c[2]; crate=$5} } END{ printf "RESULT peak_used_mb=%d peak_rustc_sum_mb=%d peak_single_rustc_mb=%d (%s)\n", pu, ps, pt, crate }' "$LOG" | tee -a "$LOG"
log "RESULT target_release=$(du -sh /target/release 2>/dev/null | cut -f1) registry=$(du -sh /usr/local/cargo/registry 2>/dev/null | cut -f1)"
if [ -f /target/release/router ]; then log "RESULT binary_bytes=$(stat -c %s /target/release/router)"; fi
grep -E "signal: 9|SIGKILL|Killed|No space left|^error" /target/cargo.log | cut -c1-200 | head -3 | sed 's/^/RESULT err: /' | tee -a "$LOG" || true
exit "$rc"
