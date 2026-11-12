# ADR-002: Split AWS and Kubernetes resources into two state files

- **Status:** Accepted
- **Date:** 2026-11-12

## Context

The previous project put everything in one root module: VPC, EKS cluster, and
Helm releases that depend on that cluster. The `kubernetes` and `helm`
providers were configured from `module.eks` outputs.

This pattern is a well-known Terraform trap. Provider configurations are
evaluated **before** the dependency graph is walked, so:

- **First apply** fails with `Invalid provider configuration` or produces an
  "unknown value in provider configuration" error, because the cluster endpoint
  does not exist yet. The usual workaround is `-target` runs, which Terraform
  itself documents as "for exceptional circumstances only".
- **Destroy** fails with `Provider configuration not present`. Terraform needs
  a working `kubernetes` provider to delete the Helm releases, but the cluster
  it reads that configuration from is already gone.
- **Any cluster-affecting change** forces the Kubernetes provider to
  re-evaluate mid-plan, producing spurious diffs on unrelated releases.

The project worked around this with a 807-line `upgrade-helper.sh` that
orchestrated targeted applies in the right order. That script existed only
because the state layout was wrong.

## Decision

Two root modules with two state files:

| Layer | Providers | Owns |
|---|---|---|
| `layers/infrastructure` | `aws` only | VPC, subnets, NAT, EKS, baseline ASG, KMS, IAM, Pod Identity associations |
| `layers/bootstrap` | `aws`, `kubernetes`, `helm`, `kubectl` | Gateway API, AWS LBC, Karpenter, add-ons, Istio |

`bootstrap` reads the cluster endpoint, CA and name through
`terraform_remote_state`. Because those values come from a **state file that
already exists** at plan time, they are never unknown, and the provider
configures cleanly on the very first run.

Authentication uses the `aws eks get-token` exec plugin rather than the
`aws_eks_cluster_auth` data source, so no bearer token is written to state.

## Alternatives considered

| Option | Why not |
|---|---|
| One state with `-target` runs | Not reproducible, not CI-friendly, documented as exceptional-use-only |
| One state with a wrapper script | What the previous project did. The script was the symptom |
| Three layers (networking / cluster / bootstrap) | Networking and EKS share a lifecycle in practice, and splitting them adds a remote-state hop for no benefit. The `create_networking` flag covers the reuse case |
| Terraform Stacks | HCP-only. Would exclude anyone running open-source Terraform or OpenTofu |

## Consequences

**Good**

- Clean `apply` and `destroy` in both directions, first time, no flags
- The add-on stack can be rebuilt without re-planning the cluster
- Blast radius is smaller: a bad Helm value cannot produce a VPC diff
- The two layers can have different IAM permissions and different approval
  gates in CI — the cluster is more sensitive than a chart version bump

**Bad / accepted**

- Two `init`/`apply` invocations, which must run in order on a new environment
- A contract between the layers. Mitigated by the `cluster_connection` and
  `addons_input` output bundles: adding a field is non-breaking, and the
  consumer side changes in one place
- `bootstrap` requires read access to the infrastructure state bucket

## Notes

The destroy ordering is the inverse: `bootstrap` first, then `infrastructure`.
Destroying `infrastructure` first strands `bootstrap`'s state pointing at a
cluster that no longer exists, and the only way out is `terraform state rm`.
