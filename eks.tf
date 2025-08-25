# IAM roles are now defined in iam.tf
####################  EKS CLUSTER ################

# eks-module-start
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.36.0"

  cluster_name                    = var.cluster_name
  cluster_version                 = var.cluster_version
  subnet_ids                      = var.subnet_ids
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_public_access_cidrs = var.cluster_public_cidrs
  vpc_id                          = var.vpc_id
  # Enable cluster creator admin permissions
  enable_cluster_creator_admin_permissions = true

  # karpenter SG-TAG
  cluster_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # Enable control plane logging and KMS envelope encryption
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_kms_key            = true
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # Security group settings
  node_security_group_enable_recommended_rules = true
  node_security_group_additional_rules = {
    cluster_to_node = {
      description                   = "Cluster to all nodes, all ports, all proto"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # egress_all = {
    #   description      = "Node all egress"
    #   protocol         = "-1"
    #   from_port        = 0
    #   to_port          = 0
    #   type             = "egress"
    #   cidr_blocks      = ["0.0.0.0/0"]
    #   ipv6_cidr_blocks = ["::/0"]
    # }
  }

  # NODE GROUPS ================================================
  eks_managed_node_groups = merge(
    {
      dev-cluster-primary = {
        # Inherits cluster version by default
        name           = var.primary_nodegroup_name
        min_size       = var.primary_min_size
        max_size       = var.primary_max_size
        desired_size   = var.primary_desired_size
        instance_types = var.node_instance_type
        use_custom_launch_template = false
        disk_size      = 100
        capacity_type  = "ON_DEMAND"  # Explicit capacity type

        # upgrade settings
        instance_refresh = {
          strategy = "Rolling"
          preferences = {
            min_healthy_percentage = 65
            instance_warmup        = "90"  # Seconds to wait after instance launch
          }
        }

        iam_role_additional_policies = {
          AmazonEBSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
          AmazonEKSCNIPolicy                = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
          AmazonEC2ContainerRegistryReadOnly= "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
          AmazonEFSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
        }
      }
    },
    var.enable_upgrade_nodegroup ? {
      dev-cluster-upgrade = {
        # Inherits cluster version by default
        name           = var.upgrade_nodegroup_name
        min_size       = var.upgrade_min_size
        max_size       = var.upgrade_max_size
        desired_size   = var.upgrade_desired_size
        instance_types = var.upgrade_instance_type
        use_custom_launch_template = false
        disk_size      = 100
        capacity_type  = "ON_DEMAND"  # Explicit capacity type
        version        = var.upgrade_version  # Target version for upgrade
        
        # Enhanced upgrade settings
        instance_refresh = {
          strategy = "Rolling"
          preferences = {
            min_healthy_percentage = 65
            instance_warmup        = "90"
          }
        }

        iam_role_additional_policies = {
          AmazonEBSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
          AmazonEKSCNIPolicy                = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
          AmazonEC2ContainerRegistryReadOnly= "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
          AmazonEFSCSIDriverPolicy          = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
        }
      }
    } : {}
  )

  # ADDON CONFIGURATION ============================================
  cluster_addons = {
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        env = {
          # Enable features for zero-downtime
          ENABLE_POD_ENI                    = "false"
          # Custom settings for your environment
          AWS_VPC_K8S_CNI_LOGLEVEL          = "DEBUG"
          # Prefix delegation settings
          ENABLE_PREFIX_DELEGATION          = "true"
          WARM_PREFIX_TARGET               = "1"
        }
      })
    }

    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.ebs_csi_irsa_role.iam_role_arn
    }

    aws-efs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      before_compute              = true
    }

    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "PRESERVE"
      configuration_values = jsonencode({
        # Ensure DNS stability during upgrades
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }]
        resources = {
          limits   = { memory = "200Mi" }
          requests = { memory = "100Mi", cpu = "100m" }
        }
      })
    }

    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }

  }

  tags = {
    terraform = "true"
    "karpenter.sh/discovery" = var.cluster_name
    "Purpose"                = "EKS-Cluster-Resources"
  }

  cluster_tags = {
    name = var.cluster_name
  }
}

data "aws_caller_identity" "current" {}

module "eks_aws-auth" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version = "20.36.0"
  manage_aws_auth_configmap = true

  aws_auth_users = var.aws_auth_users

  aws_auth_roles = local.all_aws_auth_roles
}

## this role is required for the ebs-csi driver / ebs backed persistent volumes
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.17.0"

  role_name             = "eks-${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Name        = "eks-${var.cluster_name}-ebs-csi"
    Environment = var.cluster_name
    Purpose     = "EBS CSI Driver IRSA Role"
  }
}

## create Nginx ingress Namespace
resource "kubernetes_namespace" "nginxingress_namespace" {
  metadata {
    name = "ingress-nginx"
  }
}
## create Nginx ingress-controller 
resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingres"
  repository = "file://${path.module}/n-ingres"
  chart      = "n-ingres"
  namespace  = "ingress-nginx"  # Specify the namespace here

  depends_on = [ aws_ec2_tag.update_public_subnet_tags ]

  # Increase timeout (in seconds)
  timeout = 600  # Adjust as needed
}

## create cert-manager Namespace
resource "kubernetes_namespace" "cert_manager_namespace" {
  metadata {
    name = "cert-manager"
  }
}

## Install cert-manager
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.17.2"
  namespace  = kubernetes_namespace.cert_manager_namespace.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# helm install argocd -n argocd -f values/argocd.yaml
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.8.26"
  values           = [file("argocd.yaml")]
}

##### ALB INGRESS (via Helm with IRSA) ########

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.17.0"

  role_name                         = "eks-${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  depends_on = [
    module.eks,
    aws_ec2_tag.public_subnet_elb_role,
    aws_ec2_tag.private_subnet_internal_elb_role
  ]

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.iam_role_arn
  }
}

##### KARPENTER ########

resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }
}

# Step 2: Fetch and apply Karpenter CRDs
data "http" "karpenter_nodepools_crd" {
  url = "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${var.karpenter_version}/pkg/apis/crds/karpenter.sh_nodepools.yaml"
}

data "http" "karpenter_ec2nodeclasses_crd" {
  url = "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${var.karpenter_version}/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml"
}

data "http" "karpenter_nodeclaims_crd" {
  url = "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${var.karpenter_version}/pkg/apis/crds/karpenter.sh_nodeclaims.yaml"
}

## Apply CRDs using kubectl provider
resource "kubectl_manifest" "karpenter_nodepools_crd" {
  yaml_body = data.http.karpenter_nodepools_crd.response_body
  depends_on = [kubernetes_namespace.karpenter]
}

resource "kubectl_manifest" "karpenter_ec2nodeclasses_crd" {
  yaml_body = data.http.karpenter_ec2nodeclasses_crd.response_body
  depends_on = [kubernetes_namespace.karpenter]
}

resource "kubectl_manifest" "karpenter_nodeclaims_crd" {
  yaml_body = data.http.karpenter_nodeclaims_crd.response_body
  depends_on = [kubernetes_namespace.karpenter]
}

# # Apply your entire Karpenter YAML file as a one by one

resource "kubectl_manifest" "karpenter_resources" {
  for_each = {
    for filename in local.karpenter_yaml_files :
    filename => yamldecode(file("${local.karpenter_manifest_full_path}/${filename}"))
  }

  yaml_body = yamlencode(each.value)

  depends_on = [
    kubernetes_namespace.karpenter,
    kubectl_manifest.karpenter_nodepools_crd,
    kubectl_manifest.karpenter_ec2nodeclasses_crd,
    kubectl_manifest.karpenter_nodeclaims_crd,
    kubectl_manifest.karpenter_serviceaccount_fix
  ]
}

# ## Karpenter CRDs (NodePool and EC2NodeClass)
resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
      annotations:
        kubernetes.io/description: "EC2NodeClass for running Amazon Linux 2023 nodes with custom user data"
    spec:
      amiFamily: AL2023
      blockDeviceMappings:
        - deviceName: /dev/xvda  # Root volume device for AL2023
          ebs:
            volumeSize: 40Gi     # Must be >= snapshot size (30GB)
            volumeType: gp3
            encrypted: true
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      metadataOptions:
        httpEndpoint: enabled
        httpPutResponseHopLimit: 2
        httpTokens: required
      role: "KarpenterNodeRole-${var.cluster_name}"
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
  YAML

  depends_on = [kubectl_manifest.karpenter_resources]
}

resource "kubectl_manifest" "node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["t"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"]
          nodeClassRef:
            name: default
            kind: EC2NodeClass
            group: karpenter.k8s.aws
          expireAfter: 720h # 30 * 24h = 720h
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.ec2_node_class]
}

# Update Karpenter service account with correct role ARN
resource "kubectl_manifest" "karpenter_serviceaccount_fix" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "karpenter"
      namespace = "karpenter"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller_role[0].arn
      }
    }
  })

  depends_on = [
    aws_iam_role.karpenter_controller_role
  ]
}

# Get current node group name for Karpenter deployment (optional)
data "aws_eks_node_group" "current" {
  count = var.create_node_group_data_source ? 1 : 0
  
  cluster_name    = var.cluster_name
  node_group_name = var.primary_nodegroup_name
}

# Create dynamic Karpenter deployment with correct node group name
resource "kubectl_manifest" "karpenter_deployment_fix" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "karpenter"
      namespace = "karpenter"
      labels = {
        "helm.sh/chart" = "karpenter-1.5.0"
        "app.kubernetes.io/name" = "karpenter"
        "app.kubernetes.io/instance" = "karpenter"
        "app.kubernetes.io/version" = "1.5.0"
        "app.kubernetes.io/managed-by" = "Helm"
      }
    }
    spec = {
      replicas = 2
      revisionHistoryLimit = 10
      strategy = {
        rollingUpdate = {
          maxUnavailable = 1
        }
      }
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "karpenter"
          "app.kubernetes.io/instance" = "karpenter"
        }
      }
      template = {
        metadata = {
          labels = {
            "app.kubernetes.io/name" = "karpenter"
            "app.kubernetes.io/instance" = "karpenter"
          }
        }
        spec = {
          serviceAccountName = "karpenter"
          automountServiceAccountToken = true
          securityContext = {
            fsGroup        = 65532
            runAsNonRoot   = false
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }
          priorityClassName = "system-cluster-critical"
          dnsPolicy = "ClusterFirst"
          schedulerName = "default-scheduler"
          containers = [{
            name  = "controller"
            image = "public.ecr.aws/karpenter/controller:1.5.0@sha256:339aef3f5ecdf6f94d1c7cc9d0e1d359c281b4f9b842877bdbf2acd3fa360521"
            imagePullPolicy = "IfNotPresent"
            securityContext = {
              privileged               = false
              allowPrivilegeEscalation = false
              readOnlyRootFilesystem   = true
              runAsNonRoot            = true
              runAsUser               = 65532
              runAsGroup              = 65532
              capabilities = {
                drop = ["ALL"]
              }
            }
            env = [
              {
                name  = "KUBERNETES_MIN_VERSION"
                value = "1.19.0-0"
              },
              {
                name  = "KARPENTER_SERVICE"
                value = "karpenter"
              },
              {
                name  = "LOG_LEVEL"
                value = "info"
              },
              {
                name  = "LOG_OUTPUT_PATHS"
                value = "stdout"
              },
              {
                name  = "LOG_ERROR_OUTPUT_PATHS"
                value = "stderr"
              },
              {
                name  = "METRICS_PORT"
                value = "8080"
              },
              {
                name  = "HEALTH_PROBE_PORT"
                value = "8081"
              },
              {
                name = "SYSTEM_NAMESPACE"
                valueFrom = {
                  fieldRef = {
                    fieldPath = "metadata.namespace"
                  }
                }
              },
              {
                name = "MEMORY_LIMIT"
                valueFrom = {
                  resourceFieldRef = {
                    containerName = "controller"
                    divisor       = "0"
                    resource      = "limits.memory"
                  }
                }
              },
              {
                name  = "FEATURE_GATES"
                value = "ReservedCapacity=false,SpotToSpotConsolidation=false,NodeRepair=false"
              },
              {
                name  = "BATCH_MAX_DURATION"
                value = "10s"
              },
              {
                name  = "BATCH_IDLE_DURATION"
                value = "1s"
              },
              {
                name  = "PREFERENCE_POLICY"
                value = "Respect"
              },
              {
                name  = "CLUSTER_NAME"
                value = var.cluster_name
              },
              {
                name  = "VM_MEMORY_OVERHEAD_PERCENT"
                value = "0.075"
              },
              {
                name  = "RESERVED_ENIS"
                value = "0"
              }
            ]
            port = [
              {
                name           = "http-metrics"
                containerPort  = 8080
                protocol       = "TCP"
              },
              {
                name           = "http"
                containerPort  = 8081
                protocol       = "TCP"
              }
            ]
            livenessProbe = {
              initialDelaySeconds = 30
              timeoutSeconds      = 30
              httpGet = {
                path = "/healthz"
                port = 8081
              }
            }
            readinessProbe = {
              initialDelaySeconds = 5
              timeoutSeconds      = 30
              httpGet = {
                path = "/readyz"
                port = 8081
              }
            }
            resources = {
              limits = {
                cpu    = "1"
                memory = "1Gi"
              }
              requests = {
                cpu    = "1"
                memory = "1Gi"
              }
            }
          }]
          nodeSelector = {
            "kubernetes.io/os" = "linux"
          }
          affinity = {
            nodeAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = {
                nodeSelectorTerms = [
                  {
                    matchExpressions = [
                      {
                        key      = "karpenter.sh/nodepool"
                        operator = "DoesNotExist"
                      }
                    ]
                  },
                  {
                    matchExpressions = [
                      {
                        key      = "eks.amazonaws.com/nodegroup"
                        operator = "In"
                        values   = [var.create_node_group_data_source ? data.aws_eks_node_group.current[0].node_group_name : var.primary_nodegroup_name]
                      }
                    ]
                  }
                ]
              }
            }
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      "app.kubernetes.io/instance" = "karpenter"
                      "app.kubernetes.io/name"     = "karpenter"
                    }
                  }
                  topologyKey = "kubernetes.io/hostname"
                }
              ]
            }
          }
          topologySpreadConstraints = [
            {
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/instance" = "karpenter"
                  "app.kubernetes.io/name"     = "karpenter"
                }
              }
              maxSkew             = 1
              topologyKey         = "topology.kubernetes.io/zone"
              whenUnsatisfiable   = "DoNotSchedule"
            }
          ]
          tolerations = [
            {
              key    = "CriticalAddonsOnly"
              operator = "Exists"
            }
          ]
        }
      }
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_serviceaccount_fix
  ]
}

# Update IAM role trust policy for EKS node groups to allow OIDC-based service accounts
# This needs to be done after the EKS cluster is created because OIDC provider info is only available then

# Create a null resource to trigger the IAM role trust policy update after EKS cluster is ready
// Removed null_resource that mutated nodegroup trust policies; using IRSA per-controller instead
