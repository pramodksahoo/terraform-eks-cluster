###############################################################################
# KMS key for Kubernetes Secrets envelope encryption
#
# Managed here rather than inside the EKS module so that:
#   * the key policy can be reviewed and extended independently,
#   * the key survives cluster replacement,
#   * cross-account grants (for backup or DR tooling) can be added.
#
# WARNING: scheduling this key for deletion renders every Secret in the cluster
# permanently unreadable. The deletion window defaults to the maximum of 30 days.
###############################################################################

locals {
  create_kms_key = var.enable_secrets_encryption && var.kms_key_arn == ""

  secrets_kms_key_arn = var.enable_secrets_encryption ? (
    var.kms_key_arn != "" ? var.kms_key_arn : aws_kms_key.secrets[0].arn
  ) : null
}

data "aws_iam_policy_document" "secrets_kms" {
  count = local.create_kms_key ? 1 : 0

  # Without this statement the key becomes unmanageable, because KMS does not
  # fall back to IAM for key administration.
  statement {
    sid       = "EnableIAMRootPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # The EKS service uses the key to wrap and unwrap the data encryption key that
  # protects Secrets in etcd. It never needs administrative permissions.
  statement {
    sid    = "AllowEKSServiceUse"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["eks.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "secrets" {
  count = local.create_kms_key ? 1 : 0

  description = "Envelope encryption key for Kubernetes Secrets in EKS cluster ${var.cluster_name}"

  # Annual rotation. AWS retains previous key material so existing ciphertext
  # stays readable.
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  multi_region            = false

  policy = data.aws_iam_policy_document.secrets_kms[0].json

  tags = merge(local.tags, { Name = "${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/eks/${var.cluster_name}/secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}
