###############################################################################
# Karpenter - AWS-side resources only
#
# This creates everything Karpenter needs on the AWS side:
#   * the node IAM role (and its EKS access entry, so Karpenter-launched nodes
#     may register with the cluster),
#   * the controller IAM role, scoped with tag conditions rather than "*",
#   * an EKS Pod Identity association for the controller service account,
#   * the SQS queue and EventBridge rules that deliver spot interruption,
#     rebalance and instance state-change notices.
#
# The Karpenter controller itself is installed by the eks-addons module. Keeping
# IAM here and Helm there preserves the hard boundary between the AWS provider
# and the Kubernetes providers, so this module never needs cluster connectivity.
###############################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.29"

  count = var.enable_karpenter ? 1 : 0

  cluster_name = module.eks.cluster_name

  # --- Controller identity -----------------------------------------------
  # Pod Identity rather than IRSA: no OIDC trust policy to maintain and the
  # association is removed automatically with the cluster. In v21 the Karpenter
  # submodule is Pod Identity only; IRSA support was removed entirely.
  create_iam_role                 = true
  create_pod_identity_association = true

  namespace       = var.karpenter_namespace
  service_account = var.karpenter_service_account

  iam_role_name            = "${var.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix = false
  iam_role_description     = "Karpenter controller role for EKS cluster ${var.cluster_name}"

  # --- Node identity ------------------------------------------------------
  create_node_iam_role = true
  node_iam_role_name   = "${var.cluster_name}-karpenter-node"

  node_iam_role_use_name_prefix = false
  node_iam_role_description     = "IAM role for Karpenter-provisioned nodes in ${var.cluster_name}"

  node_iam_role_additional_policies = merge(
    {
      AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    },
    var.node_additional_iam_policies,
  )

  # Registers the node role as an EC2_LINUX access entry so nodes can join.
  create_access_entry = true

  # --- Interruption handling ---------------------------------------------
  # Without this, spot reclaims give no grace period and pods are killed
  # abruptly. With it, Karpenter cordons and drains within the two-minute notice.
  enable_spot_termination = true
  queue_name              = "${var.cluster_name}-karpenter"

  tags = local.tags
}
