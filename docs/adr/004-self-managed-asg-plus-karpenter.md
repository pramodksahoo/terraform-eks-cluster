# ADR-004: Self-managed Bottlerocket ASG plus Karpenter, no Cluster Autoscaler

- **Status:** Accepted
- **Date:** 2026-11-12
- **Supersedes:** the original "managed node groups plus Karpenter" decision

## Context

Four ways to run compute on EKS today:

1. **EKS managed node groups only** — AWS-owned ASGs, fixed instance types,
   scaled by Cluster Autoscaler.
2. **Managed node groups + Karpenter** — a small, static managed group for the
   platform components, with Karpenter provisioning everything else.
3. **Self-managed ASG + Karpenter** — the same split, but the baseline group is
   a plain Auto Scaling group with a launch template we own end to end.
4. **EKS Auto Mode** — AWS runs Karpenter, the Load Balancer Controller, the
   EBS CSI driver and node lifecycle for you, on AMIs you cannot log into.

The baseline group in options 2 and 3 exists for one reason: **Karpenter cannot
provision the node it runs on.** If Karpenter is the only source of capacity
and its own pod has nowhere to schedule, the cluster cannot recover without
manual intervention. The same applies to CoreDNS and the LBC — the component
that creates nodes must not depend on a node it created.

That baseline is therefore, by design, a **fixed floor that nothing autoscales**.
Once that is true, most of what a managed node group provides stops applying.

## Decision

**Option 3.** A single self-managed Auto Scaling group running **Bottlerocket on
a pinned AMI version**, tainted and labelled, hosting only platform components —
plus **Karpenter** for every other pod. **No Cluster Autoscaler anywhere.**

| | Baseline ASG | Karpenter |
|---|---|---|
| Purpose | Bootstrap floor for platform controllers | All elastic capacity |
| Size | 2 nodes (dev) / 4 nodes (prod) | 0 → as many as pods need |
| Capacity type | 100% on-demand | Spot and on-demand |
| Instance types | A fixed short list, diversified | Chosen per pod |
| Scaled by | Nothing | Karpenter |
| AMI | Bottlerocket, pinned version | Bottlerocket, via `EC2NodeClass` |

The group is tainted `CriticalAddonsOnly=true:NoSchedule` and labelled
`node.kubernetes.io/role=system`. Every chart in `modules/eks-addons` and
`modules/istio` carries the matching toleration and node selector.

## Rationale

### Why not an EKS managed node group

A managed node group is a thin control loop over an ASG that adds value when
the group changes size and when AWS should own AMI upgrade orchestration. This
group does neither — it is a fixed floor, and its AMI version is pinned
deliberately.

What is left is friction:

- **A second opinion about capacity.** The managed node group API is one more
  thing that can decide to replace nodes, on AWS's schedule rather than ours.
- **AMI release channels, not versions.** Managed groups track a release
  version per Kubernetes version; a self-managed launch template takes an
  explicit AMI ID we resolve from SSM, so the pin is exact and visible in the
  plan.
- **No configuration we need.** Managed node groups constrain kubelet flags,
  bootstrap arguments and the launch template. Bottlerocket settings are
  simpler to express in a launch template we own.

A plain ASG that nothing resizes is both simpler and more predictable.

### Why no Cluster Autoscaler

Cluster Autoscaler and Karpenter are both capacity controllers. Running both
means two independent loops reacting to the same unschedulable pods: they
double-provision on scale-up, then fight over which nodes to drain on
scale-down. The failure mode is thrash and orphaned nodes, and it is noisy to
diagnose.

So Karpenter owns elastic capacity exclusively. Consequently the baseline ASG
carries **no `k8s.io/cluster-autoscaler/*` discovery tags**, and the
`system_node_group_autoscaling_group_tags` variable documents that adding them
is a mistake. `max_size` exists only to give an instance refresh room to surge.

### Why Bottlerocket, pinned

Bottlerocket is a container-only OS: no SSH, no shell, no package manager, a
read-only dm-verity-protected root and A/B partition sets for atomic updates.
Compared with a general-purpose distribution, the attack surface and the patch
burden are both dramatically smaller — and an immutable node is a much better
fit for a floor that is never configured by hand.

The AMI is resolved from
`/aws/service/bottlerocket/aws-k8s-<version>/<arch>/<bottlerocket_version>/image_id`
with an explicit version rather than `latest`. `latest` means AWS publishing a
release silently replaces every baseline node on the next apply, at a time we
did not choose. A `check` block warns when it is used. Upgrades are an explicit
`bottlerocket_version` bump that rolls the group via instance refresh.

Operational access, when it is genuinely needed, is the admin container over
SSM Session Manager, so `AmazonSSMManagedInstanceCore` is attached by default.

## Alternatives considered

| Option | Why not |
|---|---|
| Managed node groups only, with Cluster Autoscaler | Bin-packing is poor, scale-up is slow, and Spot diversification means hand-maintaining many node groups |
| Managed node group as the baseline | Buys nothing for a group that never autoscales and whose AMI is pinned, while adding a second control loop over capacity and constraining the launch template |
| Karpenter only | No bootstrap path. Nothing can schedule Karpenter itself |
| Both Karpenter and Cluster Autoscaler | Two controllers sizing the same cluster. Double provisioning, scale-down fights, orphaned nodes |
| AL2023 for the baseline | A full distribution with a shell and a package manager, for nodes that run four controllers. Larger attack surface and patch burden for no gain |
| Spot for the baseline | The floor must not be reclaimable. Interruption during a recovery is exactly when it hurts most |
| EKS Auto Mode | Loses control of AMIs, kubelet config, node-level security agents and the Karpenter version. Charges a premium on top of EC2. Pins the LBC version to AWS's schedule — a problem when the Gateway API support we depend on moves faster |
| Fargate for system pods | No DaemonSets, which rules out the Istio CNI agent and most node-level agents. Higher cost per pod |

## Consequences

**Good**

- One capacity controller, so no scale-up double counting and no scale-down fights
- Karpenter consolidation bin-packs across the whole instance catalogue; Spot
  diversification is one `NodePool` field rather than many node groups
- The AMI is an exact, auditable, reviewable version in the plan
- Immutable baseline nodes with no shell and no package manager
- The platform survives losing all Karpenter capacity: the baseline is still
  there, and Karpenter comes back on it

**Bad / accepted**

- We own the launch template, the user data and the AMI upgrade cadence. A
  pinned version left alone is a pinned version going stale — bumping
  `bottlerocket_version` is a real, recurring maintenance task
- Labels and taints must be expressed as Bottlerocket TOML in
  `bootstrap_extra_args`, because self-managed groups have no `labels` or
  `taints` argument. They are set by the kubelet, so **NodeRestriction** applies:
  `node.kubernetes.io/*` is allowed, `node-role.kubernetes.io/*` is rejected and
  will stop the kubelet starting
- `desired_size` is only honoured at creation — the upstream ASG hardcodes
  `ignore_changes = [desired_capacity]`. `min_size` is what holds the floor
- Debugging requires the admin container over SSM rather than SSH
- Two scaling mechanisms to reason about, even though only one scales
- The baseline is always-on cost: two small instances in dev, four in prod
- Karpenter needs correct subnet and security group discovery tags.
  `modules/networking` applies them; with `create_networking = false` the caller
  must

## Notes

If AWS Auto Mode later exposes AMI selection and decouples its add-on versions
from the cluster version, it is worth revisiting for clusters with no
node-level security agent requirement.
