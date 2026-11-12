###############################################################################
# Shared locals
###############################################################################

locals {
  # Applied to every controller. These components are what keeps the cluster
  # able to heal itself, so they are pinned to the statically-provisioned system
  # node group rather than to Karpenter capacity.
  scheduling = {
    nodeSelector = var.critical_addons_node_selector
    tolerations  = var.critical_addons_tolerations
  }

  # Priority class that ships with every Kubernetes cluster. Guarantees these
  # pods preempt application workload rather than being evicted by it.
  priority_class_name = "system-cluster-critical"
}
