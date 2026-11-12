# Environments

Per-environment backend configuration and variable files. No Terraform code
lives here — these files parameterise [`layers/`](../layers).

```
dev/
  infrastructure.backend.hcl              S3 backend for the AWS layer
  infrastructure.tfvars                   dev cluster + new VPC
  infrastructure.existing-vpc.tfvars.example   template for bring-your-own-VPC
  bootstrap.backend.hcl                   S3 backend for the Kubernetes layer
  bootstrap.tfvars                        dev add-on selection
prod/
  (the same, minus the existing-vpc template)
```

---

## Before your first run

Every file contains `CHANGE-ME` placeholders. Nothing in this repository
contains a real account ID, bucket name, certificate ARN or domain.

```bash
grep -rn CHANGE-ME environments/
```

Replace all of them. `allowed_account_ids` in particular should be set in every
environment — it is what stops a dev plan being applied to production when your
shell has the wrong profile exported.

---

## Usage

```bash
cd layers/infrastructure
terraform init  -backend-config=../../environments/dev/infrastructure.backend.hcl
terraform apply -var-file=../../environments/dev/infrastructure.tfvars

cd ../bootstrap
terraform init  -backend-config=../../environments/dev/bootstrap.backend.hcl
terraform apply -var-file=../../environments/dev/bootstrap.tfvars
```

Switching environments requires re-running `init` with the other backend file,
because the backend is what selects the state:

```bash
terraform init -reconfigure \
  -backend-config=../../environments/prod/infrastructure.backend.hcl
```

Forgetting `-reconfigure` will either reuse the previous backend or offer to
copy state between them. Read that prompt carefully; answering `yes` by reflex
copies dev state over prod.

---

## dev and prod

The differences are deliberate and worth understanding rather than copying:

| Setting | dev | prod | Why |
|---|---|---|---|
| `single_nat_gateway` | `true` | `false` | One NAT is roughly a third of the cost and an AZ-wide single point of failure |
| `az_count` | 2 | 3 | Three AZs survive one failure with quorum intact |
| `enable_flow_logs` | `false` | `true` | Flow logs cost real money at volume; in prod they are the only forensic record |
| `enable_vpc_endpoints` | `false` | `true` | Endpoints have an hourly cost but remove NAT data charges on image pulls |
| `enable_cluster_creator_admin_permissions` | `true` | `false` | In prod, access comes from explicit `access_entries`, not from whoever ran the apply |
| `enable_monitoring` | `false` | `true` | kube-prometheus-stack is not small |
| Baseline ASG size | 2 nodes (min 2 / max 4) | 4 nodes (min 4 / max 8) | `max_size` is instance-refresh headroom, not autoscaling — nothing scales this group |

`endpoint_public_access` is `false` in **both**. Reach the API over VPN, Direct
Connect, or SSM port-forwarding. If you must enable it, set
`endpoint_public_access_cidrs` — `0.0.0.0/0` is rejected by variable
validation.

---

## Adding an environment

1. Copy `dev/` to the new name.
2. Change the backend `key` — two environments sharing a state key will
   overwrite each other, and the first symptom is a plan proposing to destroy
   everything.
3. Set `environment`, `name`, `region` and `allowed_account_ids`.
4. Set `assume_role_arn` if it is a different account.

Adding a **region** works the same way: a new directory with its own backend
key and `region`. The modules hardcode no region, AZ or AMI. What is
deliberately not solved yet is cross-region peering, ACM replication and Route
53 failover — see the multi-region section of the [root README](../README.md#multi-region).

---

## State backends

The S3 bucket and DynamoDB table must exist before `init`, created once per
account outside this repository. A state backend managed by the state it holds
cannot be destroyed or recovered. Setup commands are in
[`layers/infrastructure/README.md`](../layers/infrastructure/README.md#prerequisites).

State contains resource IDs, ARNs, security group rules and cluster CA data.
Enable bucket versioning and encryption, restrict access to the deploy role,
and keep prod state in a separate bucket from dev — ideally in a separate
account.

---

## Do not commit real values

`.gitignore` excludes `*.tfvars` outside this directory. The files here are
templates and are committed **because** they contain only placeholders.

If you need environment-specific secrets — a certificate ARN is not a secret, a
repository credential is — keep them out of tfvars entirely and read them from
SSM Parameter Store or Secrets Manager at apply time. Anything passed as a
Terraform variable ends up in state, in plan output, and usually in a CI log.
