# ADR-003: EKS Pod Identity instead of IRSA

- **Status:** Accepted
- **Date:** 2026-11-12

## Context

Workloads need AWS permissions — the Load Balancer Controller calls ELB and
EC2, Karpenter calls EC2 and SQS, external-dns calls Route 53, cert-manager
solves DNS-01 challenges.

Two mechanisms exist. **IRSA** (2019) federates the cluster's OIDC provider
into IAM: each cluster registers an IAM OIDC identity provider, and each role's
trust policy names that provider's exact URL plus the service account subject.
**Pod Identity** (2023) replaces that with an EKS-managed association between a
service account and a role, where the role trusts a single AWS principal.

The previous project used IRSA, and demonstrated its two failure modes neatly:
one service account was annotated with the **node's** role ARN rather
than its own (so the pod silently inherited node permissions, including the
`AmazonS3FullAccess` attached there), and a `null_resource` with `local-exec`
rewrote node role trust policies on every apply because it was triggered by
`timestamp()`.

## Decision

Use **EKS Pod Identity** for all workload IAM, via the
`terraform-aws-modules/eks-pod-identity/aws` module. The
`eks-pod-identity-agent` add-on is installed on every cluster.

## Comparison

| | IRSA | Pod Identity |
|---|---|---|
| Trust policy | Per-cluster OIDC URL + subject condition | `pods.eks.amazonaws.com`, identical everywhere |
| Role reuse across clusters | Needs a trust policy edit per cluster | Just add an association |
| Service account annotation | Required, and a typo fails open | Not used |
| OIDC provider | One IAM IdP per cluster, counts against a hard account quota | None |
| Session tags | No | Yes — cluster, namespace, service account |
| Role chaining | Manual | Supported |
| Credential delivery | Projected token file | Agent on the node |

## Alternatives considered

| Option | Why not |
|---|---|
| Keep IRSA | Per-cluster trust policies do not scale across accounts; annotation errors fail open; the IAM OIDC provider quota is a real ceiling in multi-cluster accounts |
| Node instance profile permissions | What the old project effectively did. Every pod on the node gets every permission |
| Static access keys in Secrets | Long-lived credentials in etcd. No |

## Consequences

**Good**

- A role is portable across clusters, regions and accounts without trust
  policy edits — the thing that actually hurts at scale
- No IAM OIDC identity provider per cluster
- A missing association fails **closed**: no credentials at all, rather than
  silently inheriting the node role
- Session tags make CloudTrail readable: you can see which namespace and
  service account made a call

**Bad / accepted**

- Requires the `eks-pod-identity-agent` add-on. If it is unhealthy, workloads
  lose credentials — so it is installed as a managed add-on and is covered by
  the cluster's health checks
- Not supported on Fargate. We do not use Fargate
- A few third-party charts still assume an IRSA annotation and need their
  `serviceAccount.annotations` left empty instead

## Notes

`modules/eks` keeps `enable_irsa` available for the narrow case of a chart that
cannot work without it, but nothing in this repository uses it.
