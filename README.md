# kube-ephemeral-probe

Per-container ephemeral storage usage for Kubernetes nodes.

Scans container **logs**, **emptyDir volumes**, and **rootfs** (writable layers) to identify what's consuming ephemeral storage on your nodes.

## Motivation

Understanding ephemeral storage usage per container in Kubernetes is surprisingly hard, especially on Amazon EKS.

In practice:

- Built-in kubelet cAdvisor does not expose reliable `container_fs_*` metrics on EKS.
- Standalone cAdvisor often fails to report accurate per-container rootfs usage in EKS environments.
- CRI statistics (`crictl`, `/stats/summary`) frequently return `0` or incomplete values for `rootfs.usedBytes`.
- OverlayFS and containerd internals make it hard to map actual disk usage to a Kubernetes pod/container identity.
- When disk pressure triggers pod evictions, operators cannot determine which containers are responsible.

`kube-ephemeral-probe` bypasses metrics entirely and measures what is actually on disk.

## Usage

```bash
./kube-ephemeral-probe.sh <node-name> <scan-type>
```

### Scan types

| Type | Description |
|------|-------------|
| `logs` | Container stdout/stderr logs (`/var/log/pods`) |
| `emptydir` | EmptyDir volumes (`/var/lib/kubelet/pods`) |
| `rootfs` | Container writable layers (containerd tasks) |
| `all` | Run all scans |

### Examples

```bash
# Scan container logs (recommended first check)
./kube-ephemeral-probe.sh ip-10-1-36-21.ec2.internal logs

# Scan emptyDir volumes
./kube-ephemeral-probe.sh ip-10-1-36-21.ec2.internal emptydir

# Scan container rootfs (writable layers)
./kube-ephemeral-probe.sh ip-10-1-36-21.ec2.internal rootfs

# Run all scans
./kube-ephemeral-probe.sh ip-10-1-36-21.ec2.internal all
```

## What each scan measures

### EmptyDir 

EmptyDir volumes are used for caches, temp files, and scratch data:

- Growth depends on application behavior
- Often used for local caching or temporary processing
- Counted toward pod's ephemeral storage limit

**Path scanned:** `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/`

### Logs

- Container stdout/stderr logs
- Apps log continuously (every request, error, debug message)

**Path scanned:** `/var/log/pods/<namespace>_<pod>_<uid>/<container>/`

### Rootfs

Container writable layers contain files created/modified inside containers:

- Usually stable over time
- Contains package installations, runtime artifacts
- Less likely to grow

**Path scanned:** `/run/containerd/io.containerd.runtime.v2.task/k8s.io/<id>/rootfs/`

## How it works

`kube-ephemeral-probe` creates a privileged Kubernetes Job that:

1. Mounts host paths for containerd tasks, pod logs, and kubelet pod volumes
2. Iterates over directories and extracts Kubernetes identity (namespace, pod, container)
3. Executes `du -sb` to measure actual disk usage
4. Outputs results sorted by size

## Why `du` instead of metrics?

| Method | Typical result on EKS |
| --- | --- |
| kubelet cAdvisor | Missing or zero `container_fs_*` metrics |
| Standalone cAdvisor | Incomplete or incorrect |
| CRI stats | Often returns `0` for rootfs usage |
| Snapshot/overlay accounting | Difficult to map reliably |
| `du` on actual paths | Accurate (but expensive) |

`du` is slower and more invasive, but it does the job.

## Resource usage warning

This tool is intentionally expensive.

Running `du` against container filesystems:

- Traverses every file in scanned directories
- Causes significant disk I/O
- Can impact node performance and application latency

This is not a monitoring solution.

Recommended usage:

- Do not run continuously.
- Use only during troubleshooting or incident response
- Remove immediately after collecting results

## Security

This script runs with elevated privileges and mounts sensitive host paths.

Security characteristics:

- Requires `privileged: true`
- Mounts host paths (`/run/containerd`, `/var/log/pods`, `/var/lib/kubelet/pods`)
- Provides visibility into container runtime metadata and filesystems
- Performs filesystem traversal on the host

Security guidance:

- Do not deploy permanently
- Restrict deployment access to cluster administrators
- Run only in trusted environments

This tool is designed for controlled operational debugging, not general use.

## Tested environment

- Kubernetes: v1.32+ (EKS)
- Kubernetes: v1.32+ (kubeadm)
- Runtime: containerd
- Host OSes: Amazon Linux 2, Ubuntu 24.04
- Filesystem: overlayfs
