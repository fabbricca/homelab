# Home Server Kubernetes Platform

GitOps-managed Talos + Flux + Cilium cluster running self-hosted services on
low-power recycled hardware.

---

## 1. Overview

This repository is the single source of truth for a Talos-based Kubernetes
cluster. Terraform owns the machine layer (Talos configuration, system
extensions, and the CNI); Flux reconciles everything above it from `cluster/`.

### Core principles

* **Immutable and declarative** — no drift; all changes go through Git.
* **Rebuildable** — `terraform apply` produces a working cluster with a CNI, no
  manual bootstrap steps.
* **Layered** — Infra (Terraform) → OS (Talos) → CNI (Terraform) → add-ons and
  applications (Flux).
* **Low power** — the whole stack idles in the tens of watts.

---

## 2. Hardware

| Role | Hardware | CPU | RAM | Storage | Notes |
|------|----------|-----|-----|---------|-------|
| Control plane | HP EliteDesk 800 G2 Desktop Mini | i7-6700T (4C/8T, 35 W) | 8 GB → 24 GB | M.2 NVMe + 2.5" SATA | Schedulable |
| Worker | HP EliteDesk 800 G2 Desktop Mini | i7-6700T (4C/8T, 35 W) | 8 GB → 24 GB | M.2 NVMe + 2.5" SATA | |
| Storage | Synology DS218+ | Celeron J3355 | 2 GB (max 6 GB) | 2-bay 3.5"/2.5" | NFS + iSCSI |
| Power | Eaton 5E UPS | – | – | – | USB to the NAS, NUT server |

Notes:

* Both minis have **Intel HD Graphics 530** — Skylake QuickSync, used for
  Jellyfin transcoding. It does H.264 encode/decode and HEVC 8-bit decode; no
  AV1, no HEVC 10-bit encode.
* Desktop Mini chassis: **2 SODIMM slots, 32 GB maximum**, one M.2 and one 7 mm
  2.5" bay. Both bays hold a 500 GB HGST HTS725050A7 and are backup targets,
  not cluster storage — see section 7.
* **VT-x is enabled** in the BIOS on both nodes, as KubeVirt requires.

### Control-plane topology

One control plane and one worker. This is deliberate: with two nodes, a
2-member etcd cluster needs *both* alive for quorum, so either failure takes the
cluster down. A single member tolerates no failures either, but has only one
thing that can break, and the worker can reboot freely.

Adding a third EliteDesk gives a 3-member etcd, one-node failure tolerance and
genuine rolling upgrades. At that point, reinstate the VIP in `infra/`.

---

## 3. Network

Server subnet is `10.0.0.0/24`, kept separate from the family LAN so a
compromise of the internet-facing cluster cannot reach family devices.

```
Internet
   │
FritzBox 7530 ── 192.168.178.0/24   family LAN, WiFi, phone
   └── router ── 10.0.0.0/24        server subnet
                   ├── 10.0.0.11    control plane
                   ├── 10.0.0.12    worker
                   ├── 10.0.0.15    Synology DS218+
                   └── 10.0.0.150+  Cilium LoadBalancer pool
```

**Current state:** the TP-Link Archer VR1200v holds the server subnet. It
establishes the addressing but *cannot* enforce isolation — its stock firmware
has no destination-based ACLs and OpenWrt does not support it.

**Planned:** a TP-Link Omada ER605 **v2** replaces it. v2 is required — v1 is
end-of-life and lacks Disable NAT, which the bidirectional routing depends on.
Configured in **standalone** mode (controller mode cannot filter WAN→LAN), with
NAT disabled and a static route `10.0.0.0/24` on the FritzBox, plus:

| # | Direction | Source | Destination | Action |
|---|-----------|--------|-------------|--------|
| 1 | LAN→WAN | `10.0.0.0/24` | `192.168.178.0/24` | Deny |
| 2 | LAN→WAN | `10.0.0.0/24` | any | Permit |
| 3 | WAN→LAN | trusted host | `10.0.0.0/24` | Permit |
| 4 | WAN→LAN | `192.168.178.0/24` | `10.0.0.0/24` | Deny |

> IPv6 bypasses IPv4 ACLs entirely. Disable IPv6 on the server subnet or mirror
> every rule, or the isolation is cosmetic.

---

## 4. Provisioning

Terraform does the whole machine layer, including the CNI. There is no manual
`cilium install` and no manual `talosctl bootstrap`.

### HCP Terraform workflow

State, locking and run history live in HCP Terraform (organisation
`iberu_homelab`, workspace `homelab`). Runs execute **locally**.

That is not a preference — it is forced. The Talos API lives on `10.0.0.11` and
`10.0.0.12`, addresses on a private LAN. HashiCorp's remote runners cannot reach
them, so the **version-control and API-driven workflows cannot work here**: both
imply remote execution, and every `talos_machine_configuration_apply` would time
out. Agents would bridge it, but they are a paid feature.

So: **CLI-driven workflow, with the workspace set to Execution Mode = Local.**

One consequence to know about — HCP does not evaluate workspace variables in
local execution mode, and hides the Variables page entirely. Secrets therefore
come from a gitignored `infra/terraform.tfvars`; copy
`infra/terraform.tfvars.example` and fill it in. `*.tfvars` is gitignored.

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply

terraform output -raw kubeconfig  > ../kubeconfig
terraform output -raw talosconfig > ../talosconfig
cd ..
chmod 600 kubeconfig talosconfig
export KUBECONFIG="$PWD/kubeconfig" TALOSCONFIG="$PWD/talosconfig"
```

Then install Flux once and create the SOPS key (section 6), and the cluster
reconciles itself.

### System extensions

Built via the Talos Image Factory from `infra/files/schematic.yaml`:

| Extension | Purpose |
|-----------|---------|
| `i915`, `intel-ucode` | Jellyfin QuickSync on the HD 530 |
| `iscsi-tools` | iSCSI initiator, required by the Synology CSI driver |
| `util-linux-tools` | `blkid`/`fsck`/`mkfs` — formats the raw LUNs that CSI provisions |
| `nut-client` | graceful poweroff on AC loss |
| `nvme-cli` | `nvme smart-log` for wear and health on the NVMe boot disks |
| `tailscale` | node-level access; `talosctl` works when Kubernetes is down |

Deliberately absent: **`nfs-utils`** (csi-driver-nfs consumes NFS through its own
driver pods, not host-level `mount.nfs`), anything for **KubeVirt** (it runs on
Talos defaults), and **NIC firmware** (the onboard Intel I219-LM needs none).

Boot the nodes from the matching ISO — it carries the same extension set:

```
https://factory.talos.dev/image/<schematic-id>/<talos-version>/metal-amd64.iso
```

After editing the schematic, re-register it and update `talos_schematic_id`:

```bash
curl -X POST --data-binary @infra/files/schematic.yaml \
  https://factory.talos.dev/schematics
```

Registration is idempotent — identical content always returns the same ID. The
resulting image is `factory.talos.dev/metal-installer/<id>:<version>` (note
**metal-installer**, not `installer`).

### Optional features

Off unless their variables are set, so the initial build cannot be broken by
them:

| Variable | Enables |
|----------|---------|
| `nut_server_host` | UPS monitoring via nut-client |
| `tailscale_auth_key` | Tailscale on each node |
| `oidc_issuer_url` | API-server OIDC against Keycloak |

Secrets are `sensitive` variables, set in the gitignored
`infra/terraform.tfvars` — **not** as HCP workspace variables, which local
execution mode does not evaluate.

> OIDC is intentionally off for the first build: Keycloak runs *inside* this
> cluster, so pointing the API server at it during bootstrap is a dependency
> loop. Enable it once Keycloak is reconciled.

---

## 5. Networking (Cilium)

Cilium is rendered by Terraform (`data.helm_template`) and embedded in the
control-plane machine config as an `inlineManifest`. Talos applies it at
bootstrap and re-applies on control-plane reboot.

This is not a stylistic choice: `infra/files/cilium-prerequisite.yaml` sets
`cni: none` and disables kube-proxy, so there is no pod network for Flux to
start on until Cilium exists. **Terraform owns the CNI; Flux owns everything
above it.** Cilium's runtime configuration — the LoadBalancer IP pool and L2
announcement policy — lives in `cluster/cilium/`.

Key settings: `kubeProxyReplacement`, KubePrism at `localhost:7445`, cgroup
management left to Talos, and a capability set that deliberately omits
`SYS_MODULE` (Talos forbids workloads loading kernel modules).

MetalLB has been removed; Cilium LB IPAM and L2 announcements replace it.

### HTTP routing (Gateway API)

There is no ingress controller. `kubernetes/ingress-nginx` was **archived in
March 2026** — its final release was 4.15.1 and it will never receive another
security patch — so routing uses **Cilium's Gateway API controller** instead.
That means no extra Deployment to run, patch or pay memory for.

* Gateway API CRDs (**v1.6.1**, the minimum Cilium 1.20 accepts) are installed
  through `cluster.extraManifests` in the machine config. They are fetched by
  URL rather than inlined because the standard bundle is ~1.2 MB.
* A single `Gateway` named `main` lives in the `gateway` namespace
  (`cluster/gateway/`), with an HTTP listener for tunnelled traffic and an
  HTTPS listener for direct LAN access.
* TLS terminates **once** at the Gateway using the existing wildcard
  certificate, referenced across namespaces via a `ReferenceGrant`. The old
  per-service certificates (`keycloak-tls`, `minio-tls`) are gone.
* Services attach with `HTTPRoute` resources next to their own manifests.
* Cilium publishes the Gateway as a LoadBalancer Service named
  `cilium-gateway-main`, which is what the newt tunnel targets.

If the Gateway controller does not come up on first bootstrap, restart the
Cilium operator and agent — ordering between `extraManifests` and the Cilium
`inlineManifest` is not guaranteed. The CNI itself does not depend on these
CRDs, so bootstrap cannot fail because of them.

This has bitten once, and the failure is quiet enough to be worth describing.
The operator logged, at startup only:

```
level=error msg="Required GatewayAPI resources are not found, ..."
  error="Get \"https://localhost:7445/apis/.../gatewayclasses...\": EOF"
```

KubePrism was not answering yet, so the controller never initialised — and it
does not retry. Everything already routed kept working, because the Envoy
configuration for existing routes had been programmed by an earlier operator
instance and outlived it. Only *new* `HTTPRoute`s were affected: they stayed
with `status: null`, the Gateway's `attachedRoutes` did not increase, and
requests for the new hostname returned 404 from Envoy. Nothing anywhere reported
an error.

So: an `HTTPRoute` that never gets a status is not a broken route — it is a
Gateway controller that is not running. `kubectl -n kube-system rollout restart
deploy/cilium-operator` fixes it, and no existing route drops while it happens.

**Migration caveat:** Gateway API has no portable equivalent of nginx's
`proxy-body-size`. MinIO previously allowed 500 MB request bodies; if large S3
uploads start failing, that limit is now a data-plane (Envoy) concern.

---

## 6. Secrets (SOPS + age)

1. The age key lives at `age.key` and is **never** committed.
2. Flux decrypts manifests at reconciliation via the `sops-age` secret:

```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=./age.key
```

3. Encrypt before committing — `.sops.yaml` encrypts `data` and `stringData`
   under `cluster/`:

```bash
sops --encrypt --in-place cluster/<path>/<secret>.yaml
```

---

## 7. Storage

A Synology DS218+ at `10.0.0.15`, split by workload. Bay 1 is the HDD, bay 2 the
SSD — but the SSD pool was created first, so **the SSD is `/volume1` and the HDD
is `/volume2`**, the reverse of the bay numbering.

| Class | Backing | Protocol | Reclaim | For |
|-------|---------|----------|---------|-----|
| `synology-csi-ssd` *(default)* | `/volume1` — SSD | iSCSI, RWO | Delete | Postgres, MinIO, Keycloak, Immich's database |
| `synology-csi-ssd-retain` | `/volume1` — SSD | iSCSI, RWO | **Retain** | The Immich photo library |
| `nfs-csi` | `/volume2/HDD` | NFS 4.1, RWX | Delete | Jellyfin media |
| local-path | node NVMe | — | — | KubeVirt scratch |

Databases get block storage on flash; bulk media gets cheap sequential capacity
with the shared access Jellyfin needs.

The two SSD classes differ only in reclaim policy. Delete is right for anything
rebuildable — a Postgres that gets restored from a dump, a Prometheus TSDB.
Retain exists for the one dataset that is not: the Immich library is the
*primary* copy of the photographs, so `kubectl delete pvc` or a mistaken Flux
prune must not take the LUN with it. Recovering a Retained volume means
clearing `spec.claimRef` on the Released PV and rebinding.

Two things that will catch you out:

* **StorageClass `parameters` are immutable.** Repointing one means deleting and
  recreating it — Flux fails its dry-run otherwise.
* **A PVC's `storageClassName` is immutable too.** Moving a volume between
  classes means deleting the PVC and letting Flux recreate it, so scale the
  workload to zero first or the PVC hangs in `Terminating`.

On Talos the driver needs `--iscsiadm-path=/usr/local/sbin/iscsiadm`; without it
every attach fails with "open-iscsi tools not found on host".

### Backups

Replication is not backup, and neither is a second directory on the same disk.
Three things run nightly, deliberately landing on three different disks:

| What | When | Where | Disk |
|------|------|-------|------|
| `pg_dumpall` of the shared Postgres | 03:15 | `/volume2/HDD/postgres-backups` | NAS HDD |
| `pg_dumpall` of Immich's Postgres | 03:45 | `/volume2/HDD/immich-db-backups` | NAS HDD |
| restic of the Immich library | 04:30 | `/var/mnt/backup` on the worker | node SATA |

The databases live on the NAS SSD and are dumped to the NAS HDD, so losing
either drive does not take both a database and its backups. The Immich library
is the one dataset whose loss is unrecoverable — it is the *primary* copy of
the photographs, not a cache of something else — so it goes further, onto a
disk in a different machine entirely.

**The 2.5" bays.** Both nodes carry a 500 GB HGST, wired up by
`infra/files/backup-volume.yaml` as a Talos user volume mounted at
`/var/mnt/backup`. Two details there are worth knowing:

* The disk is selected by `disk.transport == "sata"`, **not** by `/dev/sdX`.
  Device letters are not stable on these nodes — the Synology CSI driver
  attaches an iSCSI LUN per PVC, and those take `sd*` names in attach order,
  so the control plane currently sees `sda` as a 54 GB LUN and `sdb` as the
  SATA disk while the worker sees the reverse. A config naming `/dev/sdb`
  would eventually format a PersistentVolume.
* Talos binds `/var/mnt` into the kubelet **read-only**, so a user volume is
  visible to pods but not writable by them. The backup volume needs an
  explicit `machine.kubelet.extraMounts` entry to get `rw`.

Only the worker's disk is claimed, by a `local` PV. A restic repository split
across two disks is two half-backups, so one node has to own it — and that
node has to be the one Immich runs on, because the library volume is RWO.
Hence the single `nodeSelector` in `cluster/immich/server.yaml`; the control
plane's identical disk is provisioned and idle, waiting for a failover that is
a two-line change.

**What is still missing is offsite.** Both copies are in the same room. A fire
or a theft takes the photographs. The end of
`cluster/immich/backup-restic.yaml` describes the two ways to close that —
a second restic repository on B2 or R2, or `restic copy` into one — and
Synology Hyper Backup pointed at an external USB disk covers the rest of
`/volume1` at the same time.

---

## 8. UPS

The UPS connects by USB to the Synology, which acts as the NUT server (DSM →
Control Panel → Hardware & Power → UPS → enable network UPS server). Nodes run
`nut-client` as secondaries and power off gracefully on AC loss.

On Talos, `SHUTDOWNCMD` **must** be `/sbin/poweroff` — the NUT default does not
work.

---

## 9. Remote access

Two separate paths, deliberately:

| Surface | Exposure | Path |
|---------|----------|------|
| Jellyfin | Public | newt → Pangolin tunnel → Cilium Gateway |
| Poseidon | Public | newt → Pangolin tunnel → Cilium Gateway |
| Immich | Public | newt → Pangolin tunnel → Cilium Gateway |
| `talosctl`, `kubectl`, Grafana, dashboard, KubeVirt, NAS | **Private** | Tailscale |

Admin interfaces are never internet-facing. The tunnel is outbound-only, so it
needs no port forwarding and works behind CGNAT. Tailscale nodes advertise
`10.0.0.0/24`, so approving that route once gives access to the whole server
subnet from anywhere.

---

## 10. Operations

| Action | Command |
|--------|---------|
| Reconcile everything | `flux reconcile kustomization --all` |
| Helm releases | `flux get helmreleases -A` |
| Controller logs | `kubectl -n flux-system logs deploy/helm-controller -f` |
| Cilium health | `cilium status` |
| Node extensions | `talosctl get extensions` |
| Extension configs | `talosctl get extensionserviceconfigs` |
| UPS client state | `talosctl service ext-nut-client` |

### Rebuilding from scratch

1. `terraform apply` — Talos config, extensions and Cilium
2. Extract `kubeconfig` / `talosconfig`
3. Recreate the `sops-age` secret
4. Install Flux; it reconciles `bootstrap/` then `cluster/`
5. Restore data from backups — Terraform does **not** move data

---

## 11. Roadmap

Delivered: Immich on `immich.iberu.me`; Poseidon on `poseidon.iberu.me`; Terraform rebuild on Talos v1.13.8 with Terraform-owned Cilium;
ingress-nginx replaced by Cilium Gateway API; NAS storage split across iSCSI on
the SSD and NFS on the HDD; Jellyfin transcoding on the Intel iGPU; Keycloak
moved off H2 onto Postgres; nightly database backups with retention.

Remaining:

| Phase | Work |
|-------|------|
| 5 | Observability: metrics-server, kube-prometheus-stack, Headlamp + OIDC |
| 6 | KubeVirt + CDI |
| 8 | Network isolation once the Omada ER605 v2 arrives |
| 9 | RBAC hardening: per-app ServiceAccounts, network policies, PSS labels |

Also worth doing: Flux image automation (removes the manual digest-bump
commits) and Loki alongside Grafana.

---

## 12. Known issues

* **Keycloak runs `start-dev` against the embedded H2 database.** Acceptable
  while it only serves this homelab, but it should move to `start` backed by the
  Postgres in `cluster/postgres/` before it becomes the SSO provider for the
  cluster itself. Realms now have to be created in the admin UI, or imported by
  mounting them at `/opt/keycloak/data/import`.

---

## 13. Licence

See `LICENSE`.
