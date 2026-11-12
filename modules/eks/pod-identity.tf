###############################################################################
# EKS Pod Identity roles for platform add-ons
#
# Pod Identity is used in preference to IRSA throughout:
#   * no OIDC provider trust policy to construct or keep in sync,
#   * the same role can be associated with several clusters,
#   * credentials are brokered per pod by the Pod Identity Agent, so a node's
#     instance role grants nothing to the workloads running on it.
#
# Each role below is scoped to exactly one namespace/service-account pair.
# IAM roles are created here (AWS provider only); the associations bind them to
# service accounts that the eks-gateway and eks-addons modules later create.
###############################################################################

locals {
  pod_identity_enabled = var.enable_pod_identity_roles

  # namespace / service account pairs the platform add-ons use.
  sa = {
    aws_lb_controller = { namespace = "kube-system", name = "aws-load-balancer-controller" }
    cert_manager      = { namespace = "cert-manager", name = "cert-manager" }
    external_dns      = { namespace = "external-dns", name = "external-dns" }
    ebs_csi           = { namespace = "kube-system", name = "ebs-csi-controller-sa" }
    efs_csi           = { namespace = "kube-system", name = "efs-csi-controller-sa" }
  }
}

###############################################################################
# AWS Load Balancer Controller
#
# Provisions the ALBs and NLBs behind Gateway API Gateways and Service type
# LoadBalancer objects.
###############################################################################

module "pod_identity_aws_lb_controller" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  count = local.pod_identity_enabled ? 1 : 0

  name            = "${var.cluster_name}-aws-lb-controller"
  use_name_prefix = false
  description     = "AWS Load Balancer Controller for EKS cluster ${var.cluster_name}"

  attach_aws_lb_controller_policy = true

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  count = local.pod_identity_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.sa.aws_lb_controller.namespace
  service_account = local.sa.aws_lb_controller.name
  role_arn        = module.pod_identity_aws_lb_controller[0].iam_role_arn

  tags = local.tags
}

###############################################################################
# cert-manager
#
# Only needs Route 53 access, and only for DNS-01 ACME challenges. When all
# public certificates come from ACM this role is effectively unused, but it is
# created so that internal PKI and wildcard certificates work out of the box.
###############################################################################

module "pod_identity_cert_manager" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  count = local.pod_identity_enabled ? 1 : 0

  name            = "${var.cluster_name}-cert-manager"
  use_name_prefix = false
  description     = "cert-manager Route 53 DNS-01 solver for EKS cluster ${var.cluster_name}"

  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = var.cert_manager_hosted_zone_arns

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "cert_manager" {
  count = local.pod_identity_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.sa.cert_manager.namespace
  service_account = local.sa.cert_manager.name
  role_arn        = module.pod_identity_cert_manager[0].iam_role_arn

  tags = local.tags
}

###############################################################################
# external-dns
#
# Writes Route 53 records derived from Gateway API HTTPRoute hostnames and
# Service annotations.
###############################################################################

module "pod_identity_external_dns" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  count = local.pod_identity_enabled ? 1 : 0

  name            = "${var.cluster_name}-external-dns"
  use_name_prefix = false
  description     = "external-dns Route 53 writer for EKS cluster ${var.cluster_name}"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = var.external_dns_hosted_zone_arns

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = local.pod_identity_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.sa.external_dns.namespace
  service_account = local.sa.external_dns.name
  role_arn        = module.pod_identity_external_dns[0].iam_role_arn

  tags = local.tags
}

###############################################################################
# EBS CSI driver
###############################################################################

module "pod_identity_ebs_csi" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  count = local.pod_identity_enabled ? 1 : 0

  name            = "${var.cluster_name}-ebs-csi"
  use_name_prefix = false
  description     = "EBS CSI driver for EKS cluster ${var.cluster_name}"

  attach_aws_ebs_csi_policy = true
  aws_ebs_csi_kms_arns      = var.node_ebs_kms_key_arn != "" ? [var.node_ebs_kms_key_arn] : []

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  count = local.pod_identity_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.sa.ebs_csi.namespace
  service_account = local.sa.ebs_csi.name
  role_arn        = module.pod_identity_ebs_csi[0].iam_role_arn

  tags = local.tags

  # The add-on creates the service account; the association is independent of it
  # but ordering avoids a transient permission gap on first boot.
  depends_on = [module.eks]
}

###############################################################################
# EFS CSI driver (optional)
###############################################################################

module "pod_identity_efs_csi" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  count = local.pod_identity_enabled && var.enable_efs_csi_driver ? 1 : 0

  name            = "${var.cluster_name}-efs-csi"
  use_name_prefix = false
  description     = "EFS CSI driver for EKS cluster ${var.cluster_name}"

  attach_aws_efs_csi_policy = true

  tags = local.tags
}

resource "aws_eks_pod_identity_association" "efs_csi" {
  count = local.pod_identity_enabled && var.enable_efs_csi_driver ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.sa.efs_csi.namespace
  service_account = local.sa.efs_csi.name
  role_arn        = module.pod_identity_efs_csi[0].iam_role_arn

  tags = local.tags

  depends_on = [module.eks]
}
