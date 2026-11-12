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
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 3.0.0, < 4.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0"
    }
  }
}
