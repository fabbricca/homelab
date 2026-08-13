# KubeVirt + CDI

Vendored upstream manifests, pinned:

| File | Source |
|------|--------|
| `10-kubevirt-operator.yaml` | kubevirt/kubevirt **v1.9.0** `kubevirt-operator.yaml` |
| `20-kubevirt-cr.yaml` | local — turns the operator on |
| `30-cdi-operator.yaml` | kubevirt/containerized-data-importer **v1.66.0** `cdi-operator.yaml` |
| `40-cdi-cr.yaml` | local — turns CDI on |

Vendored rather than referenced as remote kustomize bases so the repository
stays self-contained and a rebuild cannot depend on GitHub being reachable.
Numeric prefixes keep the operator ahead of its CR in apply order.

## Local patch

`30-cdi-operator.yaml` has **pod-security labels added to its Namespace**.
Talos enforces PodSecurity `baseline` cluster-wide, and upstream ships the CDI
namespace unlabelled — unlike KubeVirt's own, which already sets `privileged`.
Re-apply that patch when bumping the version; it is marked with a `LOCAL PATCH`
comment in the file.

## Upgrading

```bash
KV=v1.9.0 CDI=v1.66.0
curl -sL -o 10-kubevirt-operator.yaml \
  https://github.com/kubevirt/kubevirt/releases/download/$KV/kubevirt-operator.yaml
curl -sL -o 30-cdi-operator.yaml \
  https://github.com/kubevirt/containerized-data-importer/releases/download/$CDI/cdi-operator.yaml
# then re-apply the CDI namespace pod-security patch
```

## Hardware reality

VT-x is enabled on both nodes, so hardware virtualisation works. But both have
**8 GB**, and the cluster already sits near half of that — a guest with any
useful amount of memory will be tight until the nodes reach 24 GB.

VM disks land on `synology-csi-ssd` (iSCSI). Each node's NVMe is only 128 GB,
so local-path is not a sensible home for them.
