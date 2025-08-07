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
  vpc_id                          = var.vpc_id
  # Enable cluster creator admin permissions
  enable_cluster_creator_admin_permissions = true

  # karpenter SG-TAG
  cluster_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # Disable logging and KMS
  cluster_enabled_log_types = []
  create_kms_key            = false
  cluster_encryption_config = {}

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
          AmazonS3FullAccess       = "arn:aws:iam::aws:policy/AmazonS3FullAccess"                    # grant full access to all s3 buckets to all cluster nodes
          AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # needed for persistent volumes
          AmazonEKSCNIPolicy       = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
          AmazonEC2ContainerRegistryReadOnly  = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
          AmazonEFSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
          AWSLoadBalancerControllerIAMPolicy = "arn:aws:iam::176523951730:policy/AWSLoadBalancerControllerIAMPolicy"
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
          AmazonS3FullAccess       = "arn:aws:iam::aws:policy/AmazonS3FullAccess"                    # grant full access to all s3 buckets to all cluster nodes
          AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # needed for persistent volumes
          AmazonEKSCNIPolicy       = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
          AmazonEC2ContainerRegistryReadOnly  = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
          AmazonEFSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
          AWSLoadBalancerControllerIAMPolicy = "arn:aws:iam::176523951730:policy/AWSLoadBalancerControllerIAMPolicy"
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
      service_account_role_arn    = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks-dev-ebs-csi"
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

##### ALB INGRESS ########
# create Application Load Balancer controller service account with correct role ARN
resource "kubectl_manifest" "alb_ingress_controller_sa" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "aws-load-balancer-controller"
      namespace = "kube-system"
      labels = {
        "app.kubernetes.io/component" = "controller"
        "app.kubernetes.io/name" = "aws-load-balancer-controller"
      }
      annotations = {
        "eks.amazonaws.com/role-arn" = module.eks.eks_managed_node_groups["dev-cluster-primary"].iam_role_arn
      }
    }
  })

  depends_on = [module.eks]
}

# Apply ALB ingress resources - handle multi-document YAML files properly
locals {
  alb_ingress_manifests = flatten([
    for filename in local.alb_ingress_yaml_files : [
      for i, doc in split("---", file("${local.alb_ingress_manifest_full_path}/${filename}")) : {
        filename = filename
        index    = i
        content  = trimspace(doc)
      }
      if trimspace(doc) != ""
    ]
  ])
}

resource "kubectl_manifest" "alb_ingress_resources" {
  for_each = {
    for manifest in local.alb_ingress_manifests :
    "${manifest.filename}-${manifest.index}" => yamldecode(manifest.content)
  }

  yaml_body = yamlencode(each.value)

  depends_on = [
    kubectl_manifest.alb_ingress_controller_sa,
  ]
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
      amiSelectorTerms:
        - id: ami-0aa7cb83bdde7464f # Latest AL2023 AMI in eu-central-1 for 1.33 k8s version
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery/example: ${var.cluster_name}
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
              values: ["t3a", "t",]
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
resource "null_resource" "update_nodegroup_trust_policies" {
  triggers = {
    cluster_id = module.eks.cluster_id
    oidc_provider_arn = module.eks.oidc_provider_arn
    # Add a timestamp to force re-run if needed
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e  # Exit on any error
      
      echo "Starting IAM role trust policy update..."
      
      # Cross-platform timeout function
      timeout_cmd() {
        local duration=$1
        shift
        
        echo "Using timeout function with duration: $duration seconds"
        
        # Check if gtimeout is available (macOS with Homebrew)
        if command -v gtimeout >/dev/null 2>&1; then
          echo "Using gtimeout command"
          gtimeout $duration "$@"
        # Check if timeout is available (Linux)
        elif command -v timeout >/dev/null 2>&1; then
          echo "Using timeout command"
          timeout $duration "$@"
        else
          echo "Using fallback timeout implementation"
          # Fallback: run command in background and kill after timeout
          local cmd_pid
          "$@" &
          cmd_pid=$!
          
          # Wait for either the command to complete or timeout to expire
          local elapsed=0
          while [ $elapsed -lt $duration ]; do
            if ! kill -0 $cmd_pid 2>/dev/null; then
              # Command completed, wait for exit status
              wait $cmd_pid
              return $?
            fi
            sleep 5
            elapsed=$((elapsed + 5))
            echo "Timeout check: $elapsed/$duration seconds elapsed"
          done
          
          # Timeout expired, kill the process
          echo "Timeout expired, killing process $cmd_pid"
          kill $cmd_pid 2>/dev/null
          return 1
        fi
      }
      
      # Check cluster status first
      echo "Checking current cluster status..."
      CLUSTER_STATUS=$(aws eks describe-cluster --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
      echo "Current cluster status: $CLUSTER_STATUS"
      
      # If cluster is already active, skip the wait
      if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
        echo "Cluster is already ACTIVE, skipping wait..."
      else
        # Wait for EKS cluster to be ready with timeout
        echo "Waiting for EKS cluster to be active..."
        if ! timeout_cmd 300 aws eks wait cluster-active --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile}; then
          echo "ERROR: EKS cluster is not active after 5 minutes"
          echo "Current cluster status: $(aws eks describe-cluster --name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --query 'cluster.status' --output text 2>/dev/null || echo 'UNKNOWN')"
          exit 1
        fi
      fi
      
      echo "EKS cluster is active"
      
      # Wait a bit more for node groups to be ready
      sleep 30
      
      # List all node groups and get their IAM roles
      echo "Listing node groups..."
      NODE_GROUPS=$(aws eks list-nodegroups --cluster-name ${var.cluster_name} --region ${var.region} --profile ${var.aws_profile} --query 'nodegroups[]' --output text)
      
      if [ -z "$NODE_GROUPS" ]; then
        echo "ERROR: No node groups found"
        exit 1
      fi
      
      echo "Found node groups: $NODE_GROUPS"
      
      # Create a temporary file for the policy document
      POLICY_FILE=$(mktemp)
      
      # Update trust policy for each node group
      for NODE_GROUP in $NODE_GROUPS; do
        echo "Processing node group: $NODE_GROUP"
        
        # Get node group IAM role ARN with retry
        ROLE_ARN=""
        for i in {1..5}; do
          echo "Attempt $i to get role ARN for node group: $NODE_GROUP"
          ROLE_ARN=$(aws eks describe-nodegroup --cluster-name ${var.cluster_name} --nodegroup-name $NODE_GROUP --region ${var.region} --profile ${var.aws_profile} --query 'nodegroup.nodeRole' --output text 2>/dev/null)
          
          if [ -n "$ROLE_ARN" ]; then
            echo "Successfully got role ARN: $ROLE_ARN"
            break
          fi
          
          echo "Failed to get role ARN, retrying in 10 seconds..."
          sleep 10
        done
        
        if [ -z "$ROLE_ARN" ]; then
          echo "ERROR: Could not get role ARN for node group: $NODE_GROUP after 5 attempts"
          exit 1
        fi
        
        # Extract role name from ARN (last part after the last slash)
        ROLE_NAME=$(echo $ROLE_ARN | rev | cut -d'/' -f1 | rev)
        
        echo "Updating trust policy for role: $ROLE_NAME"
        
        # Create the policy document
        cat > $POLICY_FILE << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSNodeAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Sid": "ALBControllerAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Federated": "OIDC_PROVIDER_ARN_PLACEHOLDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "OIDC_PROVIDER_ARN_PLACEHOLDER:aud": "sts.amazonaws.com",
          "OIDC_PROVIDER_ARN_PLACEHOLDER:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    },
    {
      "Sid": "ECRServiceAccountAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Federated": "OIDC_PROVIDER_ARN_PLACEHOLDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "OIDC_PROVIDER_ARN_PLACEHOLDER:sub": "system:serviceaccount:argocd:argocd-image-updater"
        }
      }
    }
  ]
}
EOF
        
        # Replace placeholder with actual OIDC provider ARN
        if [[ "$OSTYPE" == "darwin"* ]]; then
          # macOS version of sed
          sed -i '' "s|OIDC_PROVIDER_ARN_PLACEHOLDER|${module.eks.oidc_provider_arn}|g" $POLICY_FILE
        else
          # Linux version of sed
          sed -i "s|OIDC_PROVIDER_ARN_PLACEHOLDER|${module.eks.oidc_provider_arn}|g" $POLICY_FILE
        fi
        
        # Update IAM role trust policy with retry
        for i in {1..3}; do
          echo "Attempt $i to update trust policy for role: $ROLE_NAME"
          
          if aws iam update-assume-role-policy --role-name $ROLE_NAME --policy-document file://$POLICY_FILE --region ${var.region} --profile ${var.aws_profile} 2>/dev/null; then
            echo "Successfully updated trust policy for role: $ROLE_NAME"
            break
          else
            echo "Failed to update trust policy, retrying in 5 seconds..."
            sleep 5
          fi
        done
        
        # Verify the update was successful
        echo "Verifying trust policy update..."
        CURRENT_POLICY=$(aws iam get-role --role-name $ROLE_NAME --profile ${var.aws_profile} --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)
        
        if echo "$CURRENT_POLICY" | grep -q "ALBControllerAssumeRole"; then
          echo "✅ Trust policy verification successful for role: $ROLE_NAME"
        else
          echo "❌ Trust policy verification failed for role: $ROLE_NAME"
          echo "Current policy: $CURRENT_POLICY"
          exit 1
        fi
      done
      
      # Clean up
      rm -f $POLICY_FILE
      
      echo "🎉 All IAM role trust policies updated successfully!"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up IAM role trust policies..."
    EOT
  }

  depends_on = [module.eks]
}
