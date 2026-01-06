#!/bin/sh
# Container storage scan script
# This script runs inside the K8s job pod to analyze disk usage

set -eu

TASKS="/host/run/containerd/io.containerd.runtime.v2.task/k8s.io"
LOGS="/host/var/log/pods"
KUBELET_PODS="/host/var/lib/kubelet/pods"

SKIP_PATTERN="${SKIP_PATTERN:-^kube-ephemeral-probe-}"

bytes_to_mib() {
  awk -v b="$1" 'BEGIN{printf "%.2f", b/1024/1024}'
}

print_header() {
  echo ""
  echo "=== $1 ==="
  echo "Node: $NODE_NAME"
  echo "Date: $(date)"
  echo ""
}

scan_rootfs() {
  print_header "ROOTFS DISK USAGE REPORT"

  {
    echo "MiB,NAMESPACE,POD,CONTAINER"
    for d in "$TASKS"/*; do
      [ -d "$d" ] || continue
      cfg="$d/config.json"
      [ -f "$cfg" ] || continue

      data="$(jq -r '[
        .annotations["io.kubernetes.cri.container-type"] // "",
        .annotations["io.kubernetes.cri.sandbox-namespace"] // "",
        .annotations["io.kubernetes.cri.sandbox-name"] // "",
        .annotations["io.kubernetes.cri.container-name"] // ""
      ] | join("|")' "$cfg" 2>/dev/null || echo "")"

      ctype="$(echo "$data" | cut -d'|' -f1)"
      ns="$(echo "$data" | cut -d'|' -f2)"
      pod="$(echo "$data" | cut -d'|' -f3)"
      ctr="$(echo "$data" | cut -d'|' -f4)"

      [ "$ctype" = "container" ] || continue
      [ -n "$ns" ] && [ -n "$pod" ] && [ -n "$ctr" ] || continue
      echo "$pod" | grep -q "$SKIP_PATTERN" && continue

      used=0
      [ -d "$d/rootfs" ] && used="$(du -sb "$d/rootfs" 2>/dev/null | awk '{print $1}' || echo 0)"
      mib="$(bytes_to_mib "$used")"

      echo "${mib},${ns},${pod},${ctr}"
    done | sort -t',' -k1 -rn
  } | column -t -s','
}

scan_logs() {
  print_header "CONTAINER LOGS DISK USAGE REPORT"

  {
    echo "MiB,NAMESPACE,POD,CONTAINER"
    for pod_dir in "$LOGS"/*; do
      [ -d "$pod_dir" ] || continue
      pod_full="$(basename "$pod_dir")"

      # Pod directory format: namespace_podname_uid
      ns="$(echo "$pod_full" | cut -d'_' -f1)"
      pod="$(echo "$pod_full" | sed 's/^[^_]*_//; s/_[^_]*$//')"

      echo "$pod" | grep -q "$SKIP_PATTERN" && continue

      for ctr_dir in "$pod_dir"/*; do
        [ -d "$ctr_dir" ] || continue
        ctr="$(basename "$ctr_dir")"

        used="$(du -sb "$ctr_dir" 2>/dev/null | awk '{print $1}' || echo 0)"
        mib="$(bytes_to_mib "$used")"

        echo "${mib},${ns},${pod},${ctr}"
      done
    done | sort -t',' -k1 -rn
  } | column -t -s','
}

scan_emptydir() {
  print_header "EMPTYDIR VOLUMES DISK USAGE REPORT"

  {
    echo "MiB,NAMESPACE,POD,VOLUME"
    for pod_uid_dir in "$KUBELET_PODS"/*; do
      [ -d "$pod_uid_dir" ] || continue

      emptydir_base="$pod_uid_dir/volumes/kubernetes.io~empty-dir"
      [ -d "$emptydir_base" ] || continue

      pod_uid="$(basename "$pod_uid_dir")"

      ns=""
      pod=""
      for log_pod_dir in "$LOGS"/*; do
        [ -d "$log_pod_dir" ] || continue
        log_pod_full="$(basename "$log_pod_dir")"
        if echo "$log_pod_full" | grep -q "$pod_uid"; then
          ns="$(echo "$log_pod_full" | cut -d'_' -f1)"
          pod="$(echo "$log_pod_full" | sed 's/^[^_]*_//; s/_[^_]*$//')"
          break
        fi
      done

      [ -n "$ns" ] && [ -n "$pod" ] || continue
      echo "$pod" | grep -q "$SKIP_PATTERN" && continue

      for vol_dir in "$emptydir_base"/*; do
        [ -d "$vol_dir" ] || continue
        vol="$(basename "$vol_dir")"

        used="$(du -sb "$vol_dir" 2>/dev/null | awk '{print $1}' || echo 0)"
        mib="$(bytes_to_mib "$used")"

        echo "${mib},${ns},${pod},${vol}"
      done
    done | sort -t',' -k1 -rn
  } | column -t -s','
}

main() {
  apk add --no-cache jq coreutils util-linux >/dev/null 2>&1

  scan_type="${SCAN_TYPE:?SCAN_TYPE is required}"

  case "$scan_type" in
    all)
      scan_rootfs
      scan_logs
      scan_emptydir
      ;;
    rootfs)
      scan_rootfs
      ;;
    logs)
      scan_logs
      ;;
    emptydir)
      scan_emptydir
      ;;
    *)
      echo "Error: Unknown scan type: $scan_type"
      exit 1
      ;;
  esac

  echo ""
  echo "Scan complete!"
}

main "$@"
