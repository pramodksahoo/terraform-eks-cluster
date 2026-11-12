# istio — ambient example

Istio in ambient mode on an existing EKS cluster: L4 mTLS and workload identity
for every pod in an enrolled namespace, with no sidecars. Adoption costs nothing
per pod and requires no restarts. Waypoint proxies are added later, only in the
namespaces that actually need L7 policy.

## What this creates

| Component | Detail |
|---|---|
| `istio-base` | CRDs and cluster-scoped resources, chart `1.30.8` |
| `istiod` | Control plane in `istio-system` |
| `istio-cni` | Node agent that redirects traffic into the mesh — mandatory for ambient |
| `ztunnel` | Per-node L4 proxy providing mTLS and identity |
| PeerAuthentication | Mesh-wide default, `PERMISSIVE` |
| Namespace enrolment | Ambient label applied to the `apps` namespace |

The install order is fixed: base → istiod → cni → ztunnel. The module enforces
it; applying the charts in any other order produces a control plane that never
becomes ready.

Outputs: `namespace_label_ambient` (apply it to enrol any other namespace) and
`istio_gateway_class_name` (the GatewayClass istiod reconciles, for Gateways
terminated by Istio rather than by an ALB).

## Usage

This is a bootstrap-layer example. Before `terraform apply`:

1. An EKS cluster from [`modules/eks`](../../../eks/README.md) must exist, with
   the baseline ASG available.
2. kubeconfig must be configured:
   `aws eks update-kubeconfig --region eu-central-1 --name <cluster>`.
3. The `apps` namespace must already exist. The module labels namespaces; it
   does not create them.

```bash
terraform init
terraform plan -var 'cluster_name=example-complete'
terraform apply -var 'cluster_name=example-complete'
```

Use the tagged git source with `?ref=istio-v1.0.0` in your own configurations
rather than the local `../../` path used here.

## Notes

| Decision | Why |
|---|---|
| `mesh_mode = "ambient"` | No sidecar injection, no pod restarts, no per-pod memory overhead. Enrolment is a namespace label |
| `enable_cni = true` | Ambient depends on the CNI node agent. Without it, enrolled pods run outside the mesh while reporting perfectly healthy — no mTLS, no policy, no error |
| `mtls_mode = "PERMISSIVE"` | Accepts both mTLS and plaintext during onboarding. Move to `STRICT` once every caller is inside the mesh; switching early breaks traffic from unenrolled clients |
| `node_selector` + `tolerations` | Keeps the control plane on the tainted baseline ASG (`node.kubernetes.io/role=system`, `CriticalAddonsOnly=true:NoSchedule`) rather than on Karpenter-managed capacity that can be reclaimed |
| `chart_version = "1.30.8"` | All four charts move together. Mixed chart versions across base, istiod, cni and ztunnel are not supported |

Gotchas:

- Enrolment is silent. Label a namespace and nothing restarts, nothing logs an
  obvious confirmation. Verify with `istioctl ztunnel-config workload` rather
  than assuming.
- Ambient covers L4. Authorization policies that need HTTP methods, paths or
  headers require a waypoint proxy in that namespace — which is an extra
  deployment and an extra hop.
- Istio handles east-west traffic only. North-south ingress stays with the AWS
  Load Balancer Controller via
  [`modules/eks-gateway`](../../../eks-gateway/README.md). The two compose; they
  do not compete, and you should not route internet traffic through an Istio
  gateway just because it is present.
- Cost is modest: ztunnel and the CNI agent run as DaemonSets, so the overhead
  scales with node count, not pod count.

## Cleanup

```bash
terraform destroy -var 'cluster_name=example-complete'
```

Remove the ambient label from enrolled namespaces and let traffic settle before
destroying. Tearing out ztunnel while workloads still expect mTLS will drop
connections from any peer already in `STRICT` mode. Destroy the bootstrap layer
before the infrastructure layer.
