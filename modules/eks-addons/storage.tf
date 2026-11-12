###############################################################################
# Default StorageClass
#
# EKS ships a `gp2` StorageClass marked as default. gp3 is roughly 20% cheaper
# per GiB, has baseline performance decoupled from volume size, and is the
# right default for essentially every workload. Leaving gp2 as the default
# means every PVC that omits storageClassName silently lands on the worse
# option.
#
# Two defaults at once is an error condition for the scheduler, so the gp2
# class is explicitly demoted.
###############################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  count = var.create_gp3_storage_class ? 1 : 0

  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"

  # Retain volumes created by a PVC that is later deleted? No: Delete matches
  # the lifecycle people expect from a dynamic provisioner. Workloads that need
  # data to outlive the claim should use a dedicated StorageClass.
  reclaim_policy = "Delete"

  # EBS volumes are zonal. Binding at first consumption lets the scheduler pick
  # the zone based on where the pod can actually run, instead of provisioning a
  # volume in a zone with no capacity and deadlocking the pod.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = merge(
    {
      type      = "gp3"
      encrypted = "true"
      fsType    = "ext4"
    },
    var.gp3_kms_key_id == null ? {} : {
      kmsKeyId = var.gp3_kms_key_id
    },
  )
}

# Demote the built-in gp2 class. kubernetes_annotations patches the existing
# object through server-side apply without Terraform trying to own or recreate
# a resource that EKS created.
resource "kubernetes_annotations" "gp2_not_default" {
  count = var.create_gp3_storage_class ? 1 : 0

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = true

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [kubernetes_storage_class_v1.gp3]
}
