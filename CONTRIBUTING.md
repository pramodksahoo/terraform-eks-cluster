# Contributing

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | `>= 1.10` | `brew install terraform` |
| `terraform-docs` | `>= 0.20` | `brew install terraform-docs` |
| `tflint` | `>= 0.60` | `brew install tflint` |
| `pre-commit` | `>= 4.0` | `brew install pre-commit` |
| `trivy` | `>= 0.70` | `brew install trivy` |

```bash
pre-commit install
tflint --init
```

---

## Workflow

```bash
git switch -c feat/networking-ipv6-egress

# ... edit ...

terraform fmt -recursive
pre-commit run --all-files
```

Validate what you touched:

```bash
cd modules/networking && terraform init -backend=false && terraform validate
```

Open a PR. CI validates every module, layer and example, runs `tflint` and
`trivy`, and fails if the generated documentation tables are stale.

---

## Conventions

### Files

Split by concern, not by resource type. One file per subsystem:

```
versions.tf    required_version + required_providers. Always.
variables.tf   inputs, every one with a description and a type
main.tf        locals, module calls, check blocks
<subsystem>.tf vpc.tf, subnets.tf, nat.tf, routing.tf, …
outputs.tf     outputs, every one with a description
README.md      hand-written prose + generated tables between the markers
```

### Variables

Every variable needs a `description` and an explicit `type`. Add `validation`
wherever an invalid value would otherwise fail deep inside a provider:

```hcl
variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted. Use a VPN, bastion or private endpoint."
  }
}
```

A plan-time error with a sentence of explanation is worth more than a
successful apply that produces an insecure cluster.

Use `check` blocks for cross-variable invariants that `validation` cannot
express — for example, asserting that subnet IDs are non-empty when
`create_networking = false`.

### Defaults

Default to the **secure** option, not the convenient one. Private endpoint,
encryption on, logging on. If a secure default costs money (NAT per AZ, flow
logs), leave it on and let dev environments opt out in tfvars.

### Naming

`snake_case` for Terraform identifiers, `kebab-case` for AWS and Kubernetes
resource names. No abbreviations in variable names — `endpoint_public_access`,
not `ep_pub`.

### Helm

Pass values as a single `yamlencode`:

```hcl
values = [yamlencode({ controller = { replicaCount = 2 } })]
```

Never the `set` block. The helm provider v3 changed `set {}` to `set = [...]`,
and `yamlencode` sidesteps the whole question while keeping values readable
and diffable.

Pin **chart** versions, which are not application versions. `cert-manager`
chart `v1.21.3` keeps its `v`; `karpenter` `1.15.1` does not. Verify with
`helm search repo <chart> --versions` rather than reading a GitHub release page
— not every tagged release is published to the Helm index.

Install CRDs separately with `skip_crds = true` on the chart. Helm installs
bundled CRDs on first install only and never upgrades them.

### Kubernetes manifests

Use `kubectl_manifest` (alekc), not `kubernetes_manifest`. The latter does an
API round-trip at plan time and fails outright when the CRD does not exist yet
— which is always true on a first apply.

### HCL hazards

Quote hyphenated map keys. `redis-ha = {}` parses as **subtraction**, and
`terraform validate` does not catch it:

```hcl
"redis-ha" = { enabled = false }   # correct
redis-ha   = { enabled = false }   # silently wrong
```

### Comments

Comment the **why**, never the what. A comment explaining that
`aws_subnet` creates a subnet is noise; a comment explaining why the control
plane ENIs live in the intra tier is the only record of that decision.

---

## Documentation

Input and output tables are generated. Edit variable `description` fields, then:

```bash
terraform-docs --config .terraform-docs.yml modules/<name>
```

Everything outside `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` is
hand-written and preserved. A module README should cover: what it does,
prerequisites, a quick start, the decisions a caller has to make, failure modes
and troubleshooting. CI fails on stale tables.

A change that alters the shape of the system needs an ADR in `docs/adr/`.
Number sequentially, follow the existing format, and record the alternatives
you rejected — that is the part future readers need.

---

## Testing

There is no automated test suite. Validation is:

1. `terraform validate` on every module, layer and example (CI)
2. `tflint` with the AWS ruleset (CI)
3. `trivy config --config trivy.yaml` for misconfiguration scanning (CI)
4. A real `terraform plan` against a dev account for anything non-trivial

Add an example under `modules/<name>/examples/` for any new capability. The
examples are validated in CI and are the closest thing to integration tests the
repository has.

---

## Releasing

Modules version independently via tag prefixes
([ADR-005](docs/adr/005-monorepo-with-tag-prefixes.md)).

```bash
git tag -a networking-v1.1.0 -m "networking: add IPv6 egress-only gateway"
git push origin networking-v1.1.0
```

Tag **only** the module that changed. Semver is scoped to that module:

| Bump | When |
|---|---|
| major | Breaking input/output change, or a change that replaces a resource |
| minor | New optional input, new capability, new output |
| patch | Bug fix, documentation, version pin bump with no interface change |

Anything that forces replacement of a VPC, cluster or node group is **major**,
even if the interface is unchanged. Say so explicitly in the release notes.

---

## Pull requests

Keep them scoped to one module where possible. A cross-module change is fine —
that is why this is a monorepo — but say so in the description.

Include:

- What changed and why
- Whether it is breaking, and what a consumer has to do
- A `terraform plan` excerpt for anything touching the cluster or VPC
- The ADR, if the change is architectural

Never commit: `.terraform/`, `*.tfstate`, `*.tfvars` containing real values,
account IDs, ARNs from a real account, or anything resembling a credential.
`.gitignore` covers the common cases; it does not cover an account ID pasted
into a README.
