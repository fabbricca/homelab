##############################################################################
# Cluster identity
##############################################################################

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "k8s-hs"
}

variable "cluster_endpoint" {
  description = <<-EOT
    The Kubernetes API endpoint.

    This points directly at the single control-plane node. The previous shared
    VIP (10.0.0.5) was removed: Talos' VIP relies on etcd leader election across
    multiple control planes and buys nothing with one. Reinstate it when a third
    node turns this into a 3-member control plane.
  EOT
  type        = string
  default     = "https://10.0.0.11:6443"
}

##############################################################################
# Versions
##############################################################################

variable "talos_version" {
  description = "Talos version actually installed on the nodes (via machine.install.image)"
  type        = string
  default     = "v1.13.8"
}

variable "talos_version_contract" {
  description = <<-EOT
    Talos machine-config version contract. Distinct from talos_version: this
    governs which machineconfig features are emitted, while the installed
    version comes from machine.install.image. Pinning it stops a provider
    upgrade from silently enabling new config defaults.
  EOT
  type        = string
  default     = "v1.13"
}

variable "kubernetes_version" {
  description = "Kubernetes version. 1.36.2 is the default shipped with Talos v1.13.8."
  type        = string
  default     = "1.36.2"
}

variable "talos_schematic_id" {
  description = <<-EOT
    Talos Image Factory schematic ID. Built from infra/files/schematic.yaml and
    bundles: i915 + intel-ucode (Jellyfin QuickSync), iscsi-tools and
    util-linux-tools (Synology CSI — initiator plus the blkid/mkfs tooling that
    formats its raw LUNs), nut-client (UPS shutdown), nvme-cli (disk health)
    and tailscale (remote access).

    Regenerate after editing that file with:
      curl -X POST --data-binary @infra/files/schematic.yaml \
        https://factory.talos.dev/schematics
  EOT
  type        = string
  default     = "b2ac907ea8caf73b6e80a0ecba3e64a6c522b3ead2fa29acbd20fb3bf45964d8"
}

variable "cilium_version" {
  description = "Cilium chart version rendered into the Talos inlineManifests"
  type        = string
  default     = "1.20.0"
}

variable "gateway_api_version" {
  description = <<-EOT
    Gateway API version whose CRDs are installed via cluster.extraManifests.

    Cilium 1.20 requires v1.6.1 or newer: TLSRoute moved from v1alpha2 to v1 in
    that release and Cilium's Gateway controller expects the v1 CRD to be
    present. The standard channel bundle covers every CRD Cilium needs.
  EOT
  type        = string
  default     = "v1.6.1"
}

##############################################################################
# Nodes
##############################################################################

variable "node_data" {
  description = <<-EOT
    Cluster topology. One control plane plus one worker.

    Both nodes are HP EliteDesk 800 G2 Desktop Minis (i7-6700T, HD Graphics 530,
    1x M.2 NVMe + 1x 2.5" SATA). The control plane is schedulable — see
    files/cp-scheduling.yaml — because two nodes cannot afford a dedicated one.

    The 2.5" bays are backup targets, not cluster storage. They are wired up by
    files/backup-volume.yaml, which selects the disk by transport rather than by
    a /dev/sdX path — device letters are not stable on these nodes, because the
    Synology CSI driver attaches an iSCSI LUN per PVC and those take sd* names
    in attach order.
  EOT
  type = object({
    controlplanes = map(object({
      install_disk = string
      interface    = string
      hostname     = optional(string)
    }))
    workers = map(object({
      install_disk = string
      interface    = string
      hostname     = optional(string)
    }))
  })
  default = {
    controlplanes = {
      "10.0.0.11" = {
        install_disk = "/dev/nvme0n1"
        interface    = "eno1"
        hostname     = "k8s-hs-cp-0"
      }
    }
    workers = {
      "10.0.0.12" = {
        install_disk = "/dev/nvme0n1"
        interface    = "eno1"
        hostname     = "k8s-hs-worker-0"
      }
    }
  }
}

##############################################################################
# UPS (nut-client) — optional
##############################################################################
# The Eaton UPS connects by USB to the Synology, which acts as the NUT server
# (DSM: Control Panel > Hardware & Power > UPS > enable network UPS server).
# Nodes run nut-client and power off gracefully on AC loss.
# Leave nut_server_host empty to disable.

variable "nut_server_host" {
  description = "NUT server host, e.g. ups@10.0.0.15. Empty disables nut-client."
  type        = string
  default     = ""
}

variable "nut_username" {
  description = "NUT monitor username configured on the Synology"
  type        = string
  default     = "monuser"
}

variable "nut_password" {
  description = "NUT monitor password. Set in the local gitignored terraform.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

##############################################################################
# Tailscale — optional
##############################################################################
# Runs as a Talos system extension, so talosctl works even when Kubernetes is
# broken. Nodes advertise the server subnet, which is what gives you access to
# 10.0.0.0/24 from anywhere. Routes must be approved in the Tailscale admin
# console after the first connection.
# Leave tailscale_auth_key empty to disable.

variable "tailscale_auth_key" {
  description = "Tailscale auth key. Set in the local gitignored terraform.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_advertise_routes" {
  description = "Subnet advertised to the tailnet by each node"
  type        = string
  default     = "10.0.0.0/24"
}

##############################################################################
# API server OIDC (Keycloak) — optional, off by default
##############################################################################
# Required by Headlamp: it forwards the Keycloak id_token straight to the API
# server, so without these flags login succeeds and every call 403s.
#
# Deliberately disabled for the initial build. Keycloak runs *inside* this
# cluster, so pointing the API server at it during bootstrap creates a
# dependency loop. Enable once Keycloak is reconciled and reachable.

variable "oidc_issuer_url" {
  description = "Keycloak realm issuer URL, e.g. https://keycloak.iberu.me/realms/homeserver. Empty disables OIDC."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client ID registered in Keycloak"
  type        = string
  default     = "kubernetes"
}

variable "oidc_username_claim" {
  description = "Claim mapped to the Kubernetes username"
  type        = string
  default     = "preferred_username"
}

variable "oidc_groups_claim" {
  description = "Claim mapped to Kubernetes groups, used for RBAC bindings"
  type        = string
  default     = "groups"
}
