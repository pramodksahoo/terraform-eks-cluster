# eks-addons — complete example

Karpenter and the platform controllers installed onto an existing EKS cluster:
compute autoscaling, certificate management, DNS, metrics, and an encrypted gp3
default StorageClass. Argo CD and kube-prometheus-stack are available in the
module but switched off in this example.

## What this creates

| Component | Version | Notes |
|---|---|---|
| Karpenter | chart `1.15.1` | CRDs installed from the separate `karpenter-crd` chart with `skip_crds = true` on the main release |
| Default NodePool + EC2NodeClass | — | `spot` and `on-demand`, 200 vCPU ceiling, AMI alias `al2023@latest` |
| cert-manager | `v1.21.3` | — |
| external-dns | `1.23.0` | Domain filter `example.com`, policy `upsert-only` |
| metrics-server | `3.14.0` | Required by HPA and `kubectl top` |
| gp3 StorageClass | — | Encrypted, replaces gp2 as the default |
| Argo CD | `10.18.0` | Disabled in this example |
| kube-prometheus-stack | `93.2.2` | Disabled in this example |

Every controller authenticates through EKS Pod Identity. No IRSA, no static
access keys, and no password is exposed as a Terraform variable.

## Usage

This is a bootstrap-layer example and requires a cluster first:

1. A cluster from [`modules/eks`](../../../eks/README.md) with
   `enable_karpenter = true` and `enable_pod_identity_roles = true`, so the IAM
   roles, instance profile, interruption queue and Pod Identity associations
   already exist.
2. kubeconfig configured:
   `aws eks update-kubeconfig --region eu-central-1 --name <cluster>`.
3. The `karpenter_queue_name` and `karpenter_node_iam_role_name` outputs from
   that cluster.

```bash
terraform init
terraform plan \
  -var 'cluster_name=example-complete' \
  -var 'karpenter_queue_name=example-complete-karpenter' \
  -var 'karpenter_node_iam_role_name=example-complete-karpenter-node'
terraform apply \
  -var 'cluster_name=example-complete' \
  -var 'karpenter_queue_name=example-complete-karpenter' \
  -var 'karpenter_node_iam_role_name=example-complete-karpenter-node'
```

The source is the local path `../../`; use
`?ref=eks-addons-v1.0.0` against the tagged git source in your own code.

## Notes

| Decision | Why |
|---|---|
| Separate `karpenter-crd` chart | Helm does not upgrade CRDs bundled in a chart. Managing them as their own release makes CRD upgrades explicit |
| `node_pool_cpu_limit = 200` | The hard ceiling on scale-out and the main cost guardrail. Karpenter will not exceed it regardless of pending pods |
| `spot` first, then `on-demand` | Cheapest capacity first, with on-demand as the fallback. Workloads that cannot tolerate interruption need their own NodePool |
| `node_pool_ami_alias = "al2023@latest"` | Keeps nodes patched, but the AMI changes with no Terraform diff. Pin a dated alias in production and roll it deliberately |
| `external_dns_domain_filters = ["example.com"]` | Never leave this empty. An unfiltered external-dns will act on every hosted zone its IAM role can reach |
| `external_dns_policy = "upsert-only"` | external-dns will not delete records it did not expect to own |
| `create_default_node_pool = true` | Gives the cluster something to scale onto immediately. Set it false once NodePools are owned by a GitOps repository |

Gotchas:

- Karpenter runs on the tainted baseline ASG created by
  `modules/eks` (`CriticalAddonsOnly=true:NoSchedule`, label
  `node.kubernetes.io/role=system`). It exists because Karpenter cannot
  provision the node it runs on itself.
- Changing the default StorageClass does not migrate existing gp2 volumes. Only
  new PVCs get gp3.
- Credentials are never variables. Read them from the cluster when the relevant
  add-on is enabled, using the `argocd_initial_password_command` and
  `grafana_initial_password_command` outputs.
- Cost: enabling `enable_monitoring` adds kube-prometheus-stack, which is the
  single most expensive component here in both nodes and EBS. Karpenter itself
  is free, but the capacity it provisions is not — `node_pool_cpu_limit` is your
  cap.

## Cleanup

```bash
terraform destroy
```

Delete workloads that Karpenter provisioned capacity for before destroying, and
verify that Karpenter has drained and terminated its nodes. Removing the
Karpenter controller while NodeClaims still exist leaves EC2 instances with
nothing reconciling them. Destroy the bootstrap layer entirely before the
infrastructure layer.
