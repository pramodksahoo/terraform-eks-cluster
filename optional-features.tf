# Optional Features and Enhancements
# These resources are disabled by default but can be enabled when needed

# =============================================================================
# SECURITY ENHANCEMENTS (disabled by default)
# =============================================================================

# KMS Key for EKS Encryption
resource "aws_kms_key" "eks_encryption" {
  count = 0  # Set to 1 to enable
  
  description             = "EKS cluster encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  
  tags = {
    Name = "${var.cluster_name}-encryption-key"
  }
}

resource "aws_kms_alias" "eks_encryption" {
  count = 0  # Set to 1 to enable
  
  name          = "alias/${var.cluster_name}-encryption"
  target_key_id = aws_kms_key.eks_encryption[0].key_id
}

# Enhanced Security Groups
resource "aws_security_group" "eks_cluster_enhanced" {
  count = 0  # Set to 1 to enable
  
  name_prefix = "${var.cluster_name}-cluster-"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

# =============================================================================
# MONITORING STACK (disabled by default)
# =============================================================================

# Prometheus Stack for Monitoring
resource "helm_release" "prometheus_stack" {
  count = 0  # Set to 1 to enable
  
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true
  version    = "55.5.0"

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention = "30d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
                storageClassName = "gp3"
              }
            }
          }
        }
      }
      grafana = {
        adminPassword = "admin123"  # Change in production
        persistence = {
          enabled = true
          size    = "10Gi"
        }
      }
    })
  ]
}

# Fluent Bit for Log Aggregation
resource "helm_release" "fluent_bit" {
  count = 0  # Set to 1 to enable
  
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  namespace  = "logging"
  create_namespace = true
  version    = "0.40.0"
}

# AWS Load Balancer Controller
resource "helm_release" "aws_load_balancer_controller" {
  count = 0  # Set to 1 to enable
  
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.0"
}

# =============================================================================
# NETWORK POLICIES (disabled by default)
# =============================================================================

resource "kubectl_manifest" "default_deny_network_policy" {
  count = 0  # Set to 1 to enable
  
  yaml_body = <<-YAML
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny
      namespace: default
    spec:
      podSelector: {}
      policyTypes:
      - Ingress
      - Egress
  YAML
}

# =============================================================================
# ENABLEMENT INSTRUCTIONS
# =============================================================================

# To enable any of these features:
# 1. Change the count from 0 to 1 for the desired resource
# 2. Run: terraform plan
# 3. Run: terraform apply
#
# Example:
# resource "helm_release" "prometheus_stack" {
#   count = 1  # Changed from 0 to 1
#   ...
# } 