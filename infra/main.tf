##############################################################################
# Cluster secrets and client configuration
##############################################################################

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version_contract
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = keys(var.node_data.controlplanes)
}

##############################################################################
# Cilium
##############################################################################
# Cilium is rendered here and embedded in the control-plane machine config as an
# inlineManifest, which Talos applies at bootstrap and re-applies on control
# plane reboot. It cannot be installed by Flux: files/cilium-prerequisite.yaml
# sets cni: none, so there is no pod network for Flux to start on until Cilium
# exists. Terraform therefore owns the CNI; Flux owns everything above it
# (its runtime config lives in cluster/cilium/).
#
# The helm provider only renders templates locally — no cluster connection.

data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "https://helm.cilium.io/"
  chart        = "cilium"
  version      = var.cilium_version
  kube_version = var.kubernetes_version
  include_crds = true

  values = [
    yamlencode({
      ipam = {
        mode = "kubernetes"
      }

      # Talos runs no kube-proxy (files/cilium-prerequisite.yaml disables it).
      # KubePrism exposes the API server locally on 7445, which keeps Cilium
      # working before and during control-plane restarts.
      kubeProxyReplacement = true
      k8sServiceHost       = "localhost"
      k8sServicePort       = 7445

      # SYS_MODULE is deliberately absent: Talos forbids workloads loading
      # kernel modules, and Cilium's default capability set would fail.
      securityContext = {
        capabilities = {
          ciliumAgent = [
            "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
            "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
          ]
          cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
        }
      }

      # Talos manages cgroups itself.
      cgroup = {
        autoMount = { enabled = false }
        hostRoot  = "/sys/fs/cgroup"
      }

      # Replaces MetalLB. The pool and announcement policy are reconciled by
      # Flux from cluster/cilium/.
      #
      # enableLBIPAM already defaults to true in this chart; it is set here so
      # the dependency is visible rather than implicit. There is deliberately no
      # externalIPs value — that key was removed from the chart, and external IP
      # handling now comes from kube-proxy replacement above.
      l2announcements = { enabled = true }
      enableLBIPAM    = true

      # L2 announcements are chatty against the API server; the defaults are too
      # low and cause leader-election churn.
      k8sClientRateLimit = {
        qps   = 20
        burst = 40
      }

      # One replica: this is a two-node cluster and the default of two buys
      # nothing while costing memory.
      operator = {
        replicas = 1
      }

      # Cilium's Gateway API controller replaces ingress-nginx, which was
      # archived upstream in March 2026 and receives no further security fixes.
      #
      # The CRDs are installed through cluster.extraManifests below rather than
      # embedded here — the standard bundle is ~1.2 MB, which does not belong in
      # a machine config. If the controller does not pick them up on first
      # bootstrap, restarting the Cilium operator and agent is enough; the CNI
      # itself does not depend on them, so bootstrap cannot fail because of this.
      gatewayAPI = {
        enabled = true

        # Must be "true" rather than the chart default of "auto".
        #
        # "auto" only emits the GatewayClass when .Capabilities.APIVersions
        # reports gateway.networking.k8s.io/v1/GatewayClass — a check that is
        # always false here, because helm_template renders offline with no
        # cluster to query. The resource was silently dropped from the rendered
        # manifest, so Cilium's controller ran but logged "GatewayClass cilium
        # not found" indefinitely and no Gateway was ever programmed.
        gatewayClass = { create = "true" }
      }

      # Required by the Gateway API controller. On by default, set explicitly so
      # the dependency is not lost in a future values cleanup.
      l7Proxy = true
    })
  ]
}

##############################################################################
# Config patches
##############################################################################

locals {
  nut_enabled       = var.nut_server_host != ""
  tailscale_enabled = var.tailscale_auth_key != ""
  oidc_enabled      = var.oidc_issuer_url != ""

  # Cluster-scoped settings; only meaningful on the control plane.
  controlplane_cluster_patches = concat(
    [
      file("${path.module}/files/cilium-prerequisite.yaml"),
      file("${path.module}/files/cp-scheduling.yaml"),
      file("${path.module}/files/etcd-protection.yaml"),
      yamlencode({
        cluster = {
          # Fetched by Talos at bootstrap rather than inlined: the standard
          # channel bundle is ~1.2 MB. Pinned by tag, so it is reproducible.
          extraManifests = [
            "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml",
          ]
          inlineManifests = [
            {
              name     = "cilium"
              contents = data.helm_template.cilium.manifest
            },
          ]
        }
      }),
    ],
    local.oidc_enabled ? [
      templatefile("${path.module}/templates/apiserver-oidc.yaml.tmpl", {
        oidc_issuer_url     = var.oidc_issuer_url
        oidc_client_id      = var.oidc_client_id
        oidc_username_claim = var.oidc_username_claim
        oidc_groups_claim   = var.oidc_groups_claim
      })
    ] : [],
  )
}

# Node-scoped patches, applied identically to control planes and workers.
locals {
  node_patches = {
    for ip, node in merge(var.node_data.controlplanes, var.node_data.workers) :
    ip => concat(
      [
        templatefile("${path.module}/templates/install-disk-and-hostname.yaml.tmpl", {
          hostname      = node.hostname == null ? replace(ip, ".", "-") : node.hostname
          install_disk  = node.install_disk
          schematic_id  = var.talos_schematic_id
          talos_version = var.talos_version
        }),
        file("${path.module}/files/local-path-provisioner-mounts.yaml"),
      ],
      node.second_disk != null ? [
        templatefile("${path.module}/templates/second-disk-mounts.yaml.tmpl", {
          second_disk = node.second_disk
        })
      ] : [],
      local.nut_enabled ? [
        templatefile("${path.module}/templates/nut-client.yaml.tmpl", {
          nut_server_host = var.nut_server_host
          nut_username    = var.nut_username
          nut_password    = var.nut_password
        })
      ] : [],
      local.tailscale_enabled ? [
        templatefile("${path.module}/templates/tailscale.yaml.tmpl", {
          tailscale_auth_key = var.tailscale_auth_key
          hostname           = node.hostname == null ? replace(ip, ".", "-") : node.hostname
          advertise_routes   = var.tailscale_advertise_routes
        })
      ] : [],
    )
  }
}

##############################################################################
# Machine configuration
##############################################################################

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version_contract
  kubernetes_version = var.kubernetes_version
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version_contract
  kubernetes_version = var.kubernetes_version
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = var.node_data.controlplanes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.key

  # Stage changes that would otherwise force an immediate reboot, so an apply
  # never takes the single control plane down unexpectedly.
  apply_mode = "staged_if_needing_reboot"

  config_patches = concat(
    local.node_patches[each.key],
    local.controlplane_cluster_patches,
  )
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = var.node_data.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.key
  apply_mode                  = "staged_if_needing_reboot"

  config_patches = local.node_patches[each.key]
}

##############################################################################
# Bootstrap
##############################################################################

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = keys(var.node_data.controlplanes)[0]
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = keys(var.node_data.controlplanes)[0]
}
