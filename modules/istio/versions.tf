terraform {
  required_version = ">= 1.10.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.3.0, < 4.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.5.0, < 4.0.0"
    }
    # alekc/kubectl rather than the archived gavinbunney/kubectl, and rather than
    # kubernetes_manifest: kubernetes_manifest performs an API round-trip during
    # plan and fails when the CRD it references does not exist yet, which is
    # always the case on a first apply.
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}
