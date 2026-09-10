#!/usr/bin/env bash
# scripts/free-runner-disk.sh - on a GitHub-hosted ubuntu runner: log CPU/RAM/disk and delete unused preinstalled SDKs so that
# the Rust release build (target/ > 20 GB under /var/lib/docker on /) fits the ~20 GB that ubuntu-24.04 leaves free on /.
# Idempotent; only touches well-known toolchain directories, never the runner or docker itself.
set -euo pipefail
echo "nproc=$(nproc)"; free -g; df -h / /mnt
before=$(df --output=avail -B1G / | tail -1 | tr -d ' ')
for d in /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL /usr/share/swift \
         /usr/local/share/powershell /usr/local/share/chromium /usr/local/lib/node_modules /usr/lib/jvm; do
  [ -e "$d" ] && sudo rm -rf "$d" && echo "removed $d"
done
sudo docker image prune -af >/dev/null 2>&1 || true
after=$(df --output=avail -B1G / | tail -1 | tr -d ' ')
echo "free on /: ${before}G -> ${after}G"
df -h / /mnt
