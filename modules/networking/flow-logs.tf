###############################################################################
# VPC Flow Logs
#
# Required by CIS AWS Foundations Benchmark control 3.9. Flow logs are the only
# record of pod-to-pod and pod-to-internet connections at the VPC layer and are
# usually the first artefact requested during an incident.
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.create_flow_log_group ? 1 : 0

  name              = local.flow_logs_log_group_name
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn != "" ? var.flow_logs_kms_key_arn : null

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = local.create_flow_log_group ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: this role may only be assumed on behalf of a
    # flow log belonging to this account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = local.create_flow_log_group ? 1 : 0

  statement {
    sid    = "WriteFlowLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    # Scoped to the single log group this module creates, rather than "*".
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.create_flow_log_group ? 1 : 0

  name_prefix        = "${var.name}-flow-logs-"
  description        = "Allows VPC Flow Logs to write to CloudWatch Logs for ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.create_flow_log_group ? 1 : 0

  name_prefix = "${var.name}-flow-logs-"
  role        = aws_iam_role.flow_logs[0].id
  policy      = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id       = aws_vpc.this.id
  traffic_type = var.flow_logs_traffic_type

  log_destination_type = var.flow_logs_destination_type

  log_destination = var.flow_logs_destination_arn != "" ? var.flow_logs_destination_arn : (
    local.create_flow_log_group ? aws_cloudwatch_log_group.flow_logs[0].arn : null
  )

  iam_role_arn = local.create_flow_log_group ? aws_iam_role.flow_logs[0].arn : null

  # One minute gives near-real-time visibility during an incident. The default of
  # ten minutes is usually too coarse to be useful.
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}
