terraform {
  required_version = ">= 1.9"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    # Used only to render the Cilium chart locally (data.helm_template).
    # No Kubernetes connection is made — the rendered manifest is embedded into
    # the Talos machine config as an inlineManifest.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }

  # HCP Terraform is used for state storage, locking and run history only.
  #
  # The workspace MUST be set to Execution Mode = Local. Remote execution runs
  # Terraform on HashiCorp's infrastructure, which cannot reach 10.0.0.11 or
  # 10.0.0.12 — the Talos API lives on a private LAN. Agents solve that but are
  # a paid feature.
  #
  # Consequence: HCP does not evaluate workspace variables in local execution
  # mode (the Variables page is hidden entirely), so secrets come from a local
  # gitignored terraform.tfvars — see terraform.tfvars.example.
  cloud {
    organization = "iberu_homelab"

    workspaces {
      name = "homelab"
    }
  }
}

provider "talos" {}

provider "helm" {}
