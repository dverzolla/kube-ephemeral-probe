#!/bin/bash
# https://github.com/dverzolla/kube-ephemeral-probe
#
# Scans a Kubernetes node for container ephemeral storage usage (logs, emptydir, rootfs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <node-name> <scan-type>"
  echo ""
  echo "Scan types:"
  echo "  all      - Run all scans"
  echo "  rootfs   - Container writable layers"
  echo "  logs     - Container stdout/stderr logs"
  echo "  emptydir - EmptyDir volumes"
  exit 1
}

if [ $# -lt 2 ]; then
  usage
fi

NODE_NAME="$1"
SCAN_TYPE="$2"
JOB_PREFIX="kube-ephemeral-probe-"
JOB_NAME="${JOB_PREFIX}$(date +%s)"

case "$SCAN_TYPE" in
  all|rootfs|logs|emptydir) ;;
  *) echo "Error: Invalid scan type '$SCAN_TYPE'"; usage ;;
esac

# Export variables for envsubst
export NODE_NAME SCAN_TYPE JOB_NAME
export SCAN_SCRIPT_B64=$(base64 < "$SCRIPT_DIR/scan.sh" | tr -d '\n')
export SKIP_PATTERN="^${JOB_PREFIX}"

echo "Starting disk usage scan on node: $NODE_NAME (scan type: $SCAN_TYPE)"

# Apply YAML template with variable substitution
envsubst < "$SCRIPT_DIR/job.yaml" | kubectl apply -f -

echo "Waiting for job to complete..."
kubectl wait --for=condition=complete --timeout=600s job/${JOB_NAME} 2>/dev/null || true

echo ""
kubectl logs job/${JOB_NAME}

echo ""
echo "Cleaning up..."
kubectl delete job ${JOB_NAME} --wait=false

echo "Done!"
