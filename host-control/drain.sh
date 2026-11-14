#!/usr/bin/env bash
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run this operator drain as root." >&2; exit 1; }
if systemctl is-active --quiet filius-build-worker.service; then
  echo "Stop filius-build-worker.service supervision before draining; this leaves its job running." >&2
  exit 1
fi

# systemd reads its own environment-file quoting; do not source it as shell code.
systemd-run --quiet --wait --collect --unit=filius-build-drain \
  --property=Type=exec \
  --property=EnvironmentFile=/etc/filius/orchestration.env \
  --property=KillMode=process \
  --property=UMask=0077 \
  /usr/bin/python3 /usr/local/lib/filius/host-control/controller.py drain
