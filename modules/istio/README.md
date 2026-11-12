# `istio`

Istio service mesh on EKS, in **ambient** or **sidecar** mode, with the install
order the components actually require.

Istio handles **east-west** traffic — mTLS, identity, authorization and
observability between services. North-south traffic is handled by
[`modules/eks-gateway`](../eks-gateway). The two compose; they do not compete.

---

## Contents

- [Ambient or sidecar](#ambient-or-sidecar)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Install order](#install-order)
- [Enrolling workloads](#enrolling-workloads)
- [mTLS](#mtls)
- [Istio and the Gateway API](#istio-and-the-gateway-api)
- [Upgrades](#upgrades)
- [Multi-cluster](#multi-cluster)
- [Troubleshooting](#troubleshooting)
- [Generated reference](#requirements)

---

## Ambient or sidecar

| | ambient (default) | sidecar |
|---|---|---|
| Data plane | Shared `ztunnel` per node, waypoints where needed | One Envoy per pod |
| Cost per pod | Effectively zero | ~100 MiB + CPU, per pod |
| Adoption | Label a namespace, no restart | Label a namespace, restart every pod |
| L4 mTLS + identity | Yes | Yes |
| L7 policy | Only where a waypoint is deployed | Everywhere |
| Maturity | Newer | Longest track record |

**Start with ambient.** You get mTLS and workload identity across the whole
namespace at near-zero cost and with no pod restarts, and you add waypoint
proxies later only where L7 policy is genuinely needed.

Switching modes on a live cluster is disruptive. Choose deliberately.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | `>= 1.10.0` |
| Providers | `helm >= 3.3`, `kubernetes >= 3.5`, `kubectl (alekc) >= 3.0` |
| Cluster | EKS 1.34+ with at least 2 vCPU of headroom on the baseline ASG |
| CNI | Ambient **requires** `enable_cni = true` |
| Gateway API CRDs | Only if you use the `istio` GatewayClass — install [`modules/eks-gateway`](../eks-gateway) first |

> **EKS note.** The Istio CNI agent must run on every node, including
> Karpenter-provisioned ones. A node without the agent carries traffic outside
> the mesh while looking perfectly healthy.

---

## Quick start

```hcl
module "istio" {
  source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/istio?ref=istio-v1.0.0"

  cluster_name  = "platform-prod"
  mesh_mode     = "ambient"
  chart_version = "1.30.8"

  enable_cni = true
  mtls_mode  = "PERMISSIVE"

  ambient_namespaces = ["team-a", "team-b"]

  node_selector = { "node.kubernetes.io/role" = "system" }
  tolerations = [{
    key      = "CriticalAddonsOnly"
    operator = "Equal"
    value    = "true"
    effect   = "NoSchedule"
  }]
}
```

---

## Install order

Enforced with `depends_on`, because Istio is unforgiving about it:

```
base     CRDs and cluster RBAC         nothing else can apply until these register
  ↓
istiod   control plane                 brings up the validating/mutating webhooks
  ↓
cni      node agent                    must exist before any workload is enrolled
  ↓
ztunnel  ambient L4 data plane         ambient only
  ↓
gateway  optional ingress/egress
```

Every chart is pinned to the **same** `chart_version`. Istio does not support
running mismatched minor versions across its own components, so a single
variable drives all of them.

---

## Enrolling workloads

Namespaces must already exist — this module labels them, it does not create
them.

**Ambient**, via `ambient_namespaces` or by hand. Takes effect with no pod
restart:

```bash
kubectl label namespace team-a istio.io/dataplane-mode=ambient
```

**Sidecar**, which does require a restart:

```bash
kubectl label namespace team-a istio-injection=enabled
kubectl -n team-a rollout restart deployment
```

The exact label for your configuration is in the
`namespace_label_ambient` / `namespace_label_sidecar` outputs — they account
for revisioned installs, where the label is `istio.io/rev=<revision>` instead.

The control-plane namespace is labelled `istio.io/dataplane-mode=none`: the
control plane must never be captured by its own data plane.

---

## mTLS

`mtls_mode` sets the mesh-wide default `PeerAuthentication`.

| Value | Behaviour |
|---|---|
| `PERMISSIVE` | Accepts mTLS and plaintext. Use while onboarding |
| `STRICT` | mTLS only. The correct end state |
| `null` | Do not manage mesh-wide `PeerAuthentication` at all |

Go to `STRICT` only once every caller is inside the mesh. Flipping it early
breaks anything reaching your services from outside it — including, often,
health checks from a load balancer that targets pods directly.

In ambient mode `ztunnel` already encrypts traffic between enrolled workloads;
the explicit `PeerAuthentication` is what **rejects** plaintext from outside
the mesh, so it is applied in both modes.

---

## Istio and the Gateway API

Both this module and `eks-gateway` implement Gateway API, with different
`GatewayClass` values:

| GatewayClass | Controller | Data plane | Use for |
|---|---|---|---|
| `aws-alb` / `aws-nlb` | `gateway.k8s.aws/*` | AWS ALB / NLB | North-south, public entry, ACM, WAF |
| `istio` | `istio.io/gateway-controller` | In-cluster Envoy | Mesh ingress, east-west gateways, L7 mesh policy at the edge |

A common production shape: an ALB `Gateway` terminates TLS at the edge and
forwards to pods that are themselves in the ambient mesh. You get ACM-managed
certificates and WAF at the perimeter, plus mTLS and identity inside — without
operating an Envoy fleet for north-south traffic.

Set `gateways = {}` (the default) when the ALB fronts the cluster; an Istio
ingress gateway on that path is redundant.

---

## Upgrades

Use `revision` for canary control-plane upgrades:

1. Install the new version as a revision: `revision = "1-31-0"`, bump
   `chart_version`.
2. Move one namespace: `kubectl label ns team-a istio.io/rev=1-31-0 --overwrite`.
3. Restart its workloads (sidecar) or let ambient pick it up.
4. Validate, then move the rest and remove the old revision.

Never skip a minor version. Istio supports `n-1` for the control plane to data
plane skew, nothing wider.

---

## Multi-cluster

Set these **before** the first apply — changing them later forces a full mesh
restart:

| Variable | Purpose |
|---|---|
| `mesh_id` | Shared by every cluster in the mesh. Defaults to the cluster name, which is correct only for a single-cluster mesh |
| `network` | Which network this cluster sits on. Drives east-west gateway routing |
| `trust_domain` | SPIFFE trust domain. Must be unique per mesh when federating |

If multi-region is on your roadmap, set `mesh_id` and `network` explicitly from
day one.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Ambient pods bypass the mesh | CNI agent not on that node | `kubectl -n istio-system get ds istio-cni-node -o wide` |
| `istiod` pending | Baseline ASG has no headroom | Raise `system_node_group_min_size`, or relax `node_selector` |
| Sidecars not injected | Namespace unlabelled, or pods not restarted | Check label, then `rollout restart` |
| Everything breaks after `STRICT` | A caller outside the mesh | Back to `PERMISSIVE`, enrol the caller, retry |
| `PeerAuthentication` apply fails | Applied before `istiod` CRDs | Handled by `depends_on`; re-apply if you removed it |
| Chart version not found | Not every tagged GitHub release is published to the Helm index | `helm search repo istio/istiod --versions` |

---

## Examples

| Example | Description |
|---|---|
| [`ambient`](examples/ambient) | Ambient mesh with CNI, ztunnel and namespace enrolment |

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.3.0, < 4.0.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 3.0.0, < 4.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 3.5.0, < 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.3.0, < 4.0.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 3.0.0, < 4.0.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 3.5.0, < 4.0.0 |

## Resources

| Name | Type |
|------|------|
| [helm_release.base](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.cni](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.gateway](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.istiod](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.ztunnel](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.mesh_mtls](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_labels.ambient](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/labels) | resource |
| [kubernetes_namespace_v1.istio_system](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster Istio is installed into. Used as the mesh's cluster identifier for multi-cluster meshes. | `string` | n/a | yes |
| <a name="input_ambient_namespaces"></a> [ambient\_namespaces](#input\_ambient\_namespaces) | Namespaces to enrol into the ambient mesh by applying the<br/>istio.io/dataplane-mode=ambient label. Ignored unless mesh\_mode is "ambient".<br/><br/>The namespaces must already exist — this module labels them, it does not create<br/>them. Enrolment takes effect without restarting pods. | `list(string)` | `[]` | no |
| <a name="input_base_values"></a> [base\_values](#input\_base\_values) | Additional values merged over the computed istio base chart values. | `any` | `{}` | no |
| <a name="input_chart_repository"></a> [chart\_repository](#input\_chart\_repository) | Helm repository serving the Istio charts. | `string` | `"https://istio-release.storage.googleapis.com/charts"` | no |
| <a name="input_chart_version"></a> [chart\_version](#input\_chart\_version) | Istio chart version applied to every Istio chart (base, istiod, cni, ztunnel,<br/>gateway). All Istio components must run the same minor version, so a single<br/>variable is deliberately used rather than one per chart.<br/><br/>Note this is the *chart* version from the Helm index, which is not always<br/>published for every tagged GitHub release. | `string` | `"1.30.8"` | no |
| <a name="input_cni_values"></a> [cni\_values](#input\_cni\_values) | Additional values merged over the computed istio-cni chart values. Use for node-specific paths or resource tuning. | `any` | `{}` | no |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | Create the control-plane namespace. Set to false when the namespace is managed elsewhere, for example by a namespace-as-code pipeline. | `bool` | `true` | no |
| <a name="input_enable_access_logging"></a> [enable\_access\_logging](#input\_enable\_access\_logging) | Emit Envoy/ztunnel access logs to stdout. Costs log ingest volume but is close to essential for debugging a mesh. | `bool` | `true` | no |
| <a name="input_enable_cni"></a> [enable\_cni](#input\_enable\_cni) | Install the Istio CNI node agent. Required for ambient mode. For sidecar mode it<br/>is optional but recommended: it removes the need for the NET\_ADMIN capability on<br/>every injected pod by doing traffic redirection at CNI time instead of through an<br/>init container. | `bool` | `true` | no |
| <a name="input_enable_pod_disruption_budget"></a> [enable\_pod\_disruption\_budget](#input\_enable\_pod\_disruption\_budget) | Create a PodDisruptionBudget for istiod. Prevents a node drain from taking the whole control plane out at once. | `bool` | `true` | no |
| <a name="input_gateways"></a> [gateways](#input\_gateways) | Istio ingress/egress gateway deployments to create from the `gateway` chart, keyed<br/>by Helm release name.<br/><br/>A gateway is only needed when terminating traffic with Istio itself. When the<br/>AWS Load Balancer Controller fronts the cluster through the Gateway API, north-south<br/>traffic already terminates on an ALB or NLB and an Istio gateway is redundant for<br/>that path — leave this empty in that case.<br/><br/>Each entry:<br/>  namespace    - namespace to deploy into. Defaults to the control-plane namespace.<br/>  service\_type - Kubernetes Service type. "LoadBalancer" provisions an NLB through<br/>                 the AWS Load Balancer Controller; "ClusterIP" is correct when an<br/>                 ALB targets the gateway pods directly.<br/>  annotations  - Service annotations, e.g. NLB tuning or ACM certificate ARNs.<br/>  labels       - extra labels applied to the Service and Deployment.<br/>  values       - arbitrary additional values merged over the computed values. | <pre>map(object({<br/>    namespace    = optional(string)<br/>    service_type = optional(string, "ClusterIP")<br/>    annotations  = optional(map(string), {})<br/>    labels       = optional(map(string), {})<br/>    values       = optional(any, {})<br/>  }))</pre> | `{}` | no |
| <a name="input_helm_timeout"></a> [helm\_timeout](#input\_helm\_timeout) | Seconds to wait for each Helm release to become ready. | `number` | `600` | no |
| <a name="input_istiod_replicas"></a> [istiod\_replicas](#input\_istiod\_replicas) | Number of istiod replicas. Two or more keeps the control plane available during a node replacement. | `number` | `2` | no |
| <a name="input_istiod_values"></a> [istiod\_values](#input\_istiod\_values) | Additional values merged over the computed istiod chart values. This is the main tuning surface: tracing, access logging, resource requests, HPA settings and mesh config all live here. | `any` | `{}` | no |
| <a name="input_mesh_id"></a> [mesh\_id](#input\_mesh\_id) | Identifier shared by every cluster that belongs to the same mesh. Clusters with the<br/>same mesh\_id and a shared trust domain can federate. Defaults to the cluster name,<br/>which is correct for a single-cluster mesh but must be set explicitly before adding<br/>a second cluster — changing it later forces a full mesh restart. | `string` | `null` | no |
| <a name="input_mesh_mode"></a> [mesh\_mode](#input\_mesh\_mode) | Data-plane mode for the mesh.<br/><br/>  "ambient"  - sidecar-less. ztunnel provides L4 mTLS for every pod in a labelled<br/>               namespace at near-zero per-pod cost; waypoint proxies are deployed<br/>               only where L7 policy is actually needed. Requires the CNI plugin.<br/>               Recommended for new installations.<br/>  "sidecar"  - classic injected envoy sidecar per pod. Higher resource cost and<br/>               requires a pod restart to adopt, but has the longest track record<br/>               and full L7 features everywhere without waypoints.<br/><br/>Switching modes on a live cluster is disruptive; pick one deliberately. | `string` | `"ambient"` | no |
| <a name="input_mtls_mode"></a> [mtls\_mode](#input\_mtls\_mode) | Mesh-wide default PeerAuthentication mode.<br/><br/>  "STRICT"     - workloads accept mTLS only. The correct end state, but it breaks<br/>                 any traffic from outside the mesh that is not mTLS.<br/>  "PERMISSIVE" - accept both mTLS and plaintext. Use while onboarding workloads,<br/>                 then move to STRICT.<br/>  null         - do not manage mesh-wide PeerAuthentication at all. | `string` | `"PERMISSIVE"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the Istio control plane runs in. istio-system is assumed by a large amount of tooling and documentation; change it only with good reason. | `string` | `"istio-system"` | no |
| <a name="input_network"></a> [network](#input\_network) | Name of the network this cluster sits on. Only relevant for multi-network meshes; pods in different networks reach each other through east-west gateways. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector applied to the Istio control-plane components. Pin the control plane to the baseline system ASG so it is never evicted onto a Karpenter spot node. | `map(string)` | `{}` | no |
| <a name="input_outbound_traffic_policy"></a> [outbound\_traffic\_policy](#input\_outbound\_traffic\_policy) | How the mesh treats traffic to hosts that are not in its service registry.<br/><br/>  "ALLOW\_ANY"    - pass unknown destinations through. Operationally easy.<br/>  "REGISTRY\_ONLY" - block anything without an explicit ServiceEntry. A meaningful<br/>                   egress control and a common compliance requirement, but it will<br/>                   break workloads that call undeclared external endpoints. | `string` | `"ALLOW_ANY"` | no |
| <a name="input_revision"></a> [revision](#input\_revision) | Control-plane revision name, used for revision-based (canary) upgrades. When set,<br/>istiod is installed as a revision and namespaces opt in with<br/>istio.io/rev=<revision> instead of istio-injection=enabled.<br/><br/>Leave null for a default, unrevisioned install. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags recorded as Helm release labels. Kubernetes label syntax applies, so keys and values must be alphanumeric plus -, \_ and . | `map(string)` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations applied to the Istio control-plane components. Required when the target nodes carry a taint such as CriticalAddonsOnly. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string)<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_trust_domain"></a> [trust\_domain](#input\_trust\_domain) | SPIFFE trust domain for workload identities. Defaults to cluster.local. Must be unique per mesh when federating. | `string` | `"cluster.local"` | no |
| <a name="input_ztunnel_values"></a> [ztunnel\_values](#input\_ztunnel\_values) | Additional values merged over the computed ztunnel chart values. Ignored unless mesh\_mode is "ambient". | `any` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_ambient_enrolled_namespaces"></a> [ambient\_enrolled\_namespaces](#output\_ambient\_enrolled\_namespaces) | Namespaces labelled for ambient mesh enrolment by this module. |
| <a name="output_chart_version"></a> [chart\_version](#output\_chart\_version) | Istio chart version installed across all components. |
| <a name="output_gateway_release_names"></a> [gateway\_release\_names](#output\_gateway\_release\_names) | Helm release names of the Istio gateway deployments created by this module. |
| <a name="output_istio_gateway_class_name"></a> [istio\_gateway\_class\_name](#output\_istio\_gateway\_class\_name) | Name of the GatewayClass istiod reconciles. Use this on a Gateway resource to have<br/>Istio terminate traffic itself, as opposed to the AWS Load Balancer Controller<br/>classes which terminate on an ALB or NLB. |
| <a name="output_mesh_id"></a> [mesh\_id](#output\_mesh\_id) | Mesh identifier. Every cluster joining this mesh must use the same value. |
| <a name="output_mesh_mode"></a> [mesh\_mode](#output\_mesh\_mode) | Data-plane mode the mesh was installed with. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the Istio control plane is installed in. |
| <a name="output_namespace_label_ambient"></a> [namespace\_label\_ambient](#output\_namespace\_label\_ambient) | Label a namespace with this key/value to enrol it into the ambient mesh. Empty in sidecar mode. |
| <a name="output_namespace_label_sidecar"></a> [namespace\_label\_sidecar](#output\_namespace\_label\_sidecar) | Label a namespace with this key/value to enable sidecar injection for it. Empty in ambient mode. |
| <a name="output_revision"></a> [revision](#output\_revision) | Control-plane revision, or null for an unrevisioned install. |
| <a name="output_trust_domain"></a> [trust\_domain](#output\_trust\_domain) | SPIFFE trust domain issued to workloads in this mesh. |
<!-- END_TF_DOCS -->
