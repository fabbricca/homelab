output "talosconfig" {
  description = "talosctl client configuration"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubernetes client configuration"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "controlplane_nodes" {
  description = "Control-plane node addresses"
  value       = keys(var.node_data.controlplanes)
}

output "worker_nodes" {
  description = "Worker node addresses"
  value       = keys(var.node_data.workers)
}

output "installer_image" {
  description = "Factory installer image applied to the nodes"
  value       = "factory.talos.dev/metal-installer/${var.talos_schematic_id}:${var.talos_version}"
}

output "optional_features" {
  description = "Which variable-gated features are enabled in this configuration"
  # local.tailscale_enabled derives from a sensitive variable, so the boolean
  # inherits that marking. Whether a key was supplied reveals nothing, so it is
  # explicitly downgraded rather than marking the whole output sensitive.
  value = {
    nut_client     = local.nut_enabled
    tailscale      = nonsensitive(local.tailscale_enabled)
    apiserver_oidc = local.oidc_enabled
  }
}
