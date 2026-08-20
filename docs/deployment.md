# Deploying: from zero to a running environment

Start-to-finish runbook for taking one of `environments/{dev,staging,prod}` from code to running
infrastructure in its own AWS account: getting the account and tooling ready, running
`scripts/bootstrap-env.sh`, confirming it worked, then the ongoing plan/apply cycle. See
[ADR-0009](architecture-decisions/0009-environment-scoped-oidc-manual-cicd.md) for the reasoning
behind the overall design (supersedes the earlier ADR-0008 model), and
[operator-setup.md](operator-setup.md) for tooling install, authentication, and troubleshooting
details this doc doesn't repeat.

Each environment (dev/staging/prod) is its own AWS account, so steps 1-8 below happen once **per
account**, not once total.

## 1. Prerequisites: the AWS account

You need an AWS account for this environment, and credentials into it that are more privileged
than the day-to-day `PowerUserAccess` role this platform's CI deploy role gets later.

`bootstrap/main.tf` — run once, by you, from your laptop — creates:

- An IAM OIDC provider (`aws_iam_openid_connect_provider.github_actions`)
- An IAM role + inline policies for the CI deploy role (`aws_iam_role.github_actions_deploy`,
  `aws_iam_role_policy.github_actions_iam_scope`)
- An MFA-gated KMS key administrator role (`aws_iam_role.kms_key_administrator`) that every
  `global/kms` CMK's key policy trusts — see [step 4b](#4b-the-kms-key-administrator-role) and
  [ADR-0013](architecture-decisions/0013-kms-key-administrator-role.md)
- A KMS CMK + alias for Terraform state encryption
- An S3 bucket (versioned, KMS-encrypted, public-access-blocked) for Terraform state

None of that is covered by `PowerUserAccess`, which explicitly excludes IAM management. Your own
credentials for this one-time step need at least: `iam:CreateOpenIDConnectProvider`,
`iam:CreateRole`, `iam:PutRolePolicy`, `iam:TagRole`, `iam:AttachRolePolicy`, `kms:CreateKey`,
`kms:CreateAlias`, and the usual `s3:CreateBucket`/`PutBucket*` actions — in practice, an
`AdministratorAccess`-equivalent SSO role/permission set for this one pass is the path of least
resistance. (If you re-run the script later against a lower-privileged role — e.g. after the
first bootstrap apply partially succeeded — a re-run only needs whatever the first pass didn't
already create; `terraform apply` is idempotent and skips what's already there.)

You also need **admin or maintain access on the GitHub repo** — creating a GitHub Environment and
its required-reviewers policy via `gh api PUT .../environments/<name>` requires it. A token that
only has `repo`/`read:org` scope will fail later at that step with a 403/404.

## 2. Log in from your terminal

Follow [operator-setup.md §2](operator-setup.md#2-authenticate) to log in to AWS and GitHub if
you haven't already (`aws sso login`, `gh auth login`).

One thing specific to this step: confirm the account ID `aws sts get-caller-identity` prints
matches the environment you intend to bootstrap — the CIDR ranges and bucket names below are all
account-specific, and applying the wrong environment's values into the wrong account is exactly
the kind of mistake this step exists to catch.

## 3. Confirm local tooling

```bash
terraform version   # >= 1.10 — S3 native state locking (use_lockfile) needs it
aws --version        # AWS CLI v2
gh --version
jq --version
```

See [operator-setup.md](operator-setup.md#1-install-the-tooling) for install commands per tool if
any are missing.

## 4. Fill in the bootstrap variables file

Same idea as `terraform.tfvars`: copy the example, fill in real values, and the script reads it
itself — no manual `source` step, nothing to re-export by hand on your next run.

```bash
cp scripts/.env.example scripts/.env.dev
$EDITOR scripts/.env.dev
```

`scripts/.env.<environment>` is gitignored (matches `.env.*` in `.gitignore`; only `.env.example`
is actually committed). `scripts/bootstrap-env.sh <environment>` auto-loads
`scripts/.env.<environment>` if it exists, before doing anything else — you just run the script
directly once the file is filled in (step 7). If you'd rather not keep a file at all (e.g. a CI
runner injecting secrets directly), exporting the same variables in your shell still works with
no file present.

`scripts/.env.example` looks like this:

```bash
# scripts/.env.dev — after `cp scripts/.env.example scripts/.env.dev`
export GITHUB_REPO="<owner>/infra-blueprint-NRT-AWS"
export AWS_REGION="us-east-1"
export COST_CENTER="REPLACE-ME"
export DATA_CLASSIFICATION="REPLACE-ME"
export OWNER="REPLACE-ME"
export RETENTION_POLICY="REPLACE-ME"

# Real, non-overlapping CIDRs (see ADR-0004) — never the RFC 5737 placeholders from
# terraform.tfvars.example in a real apply.
export NETWORK_SHARED_VPC_CIDR="10.0.0.0/24"
export NETWORK_SHARED_PRIVATE_SUBNET_CIDRS='["10.0.0.0/26","10.0.0.64/26"]'
export INTEGRATION_VPC_CIDR="10.0.1.0/24"
export INTEGRATION_PRIVATE_SUBNET_CIDRS='["10.0.1.0/26","10.0.1.64/26"]'
export NRT_PROCESSING_VPC_CIDR="10.0.2.0/24"
export NRT_PROCESSING_PRIVATE_SUBNET_CIDRS='["10.0.2.0/26","10.0.2.64/26"]'
export DATA_VPC_CIDR="10.0.3.0/24"
export DATA_PRIVATE_SUBNET_CIDRS='["10.0.3.0/26","10.0.3.64/26"]'

# Required — see step 4b below for what this controls and who it should be per environment.
export KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS='["arn:aws:iam::111122223333:role/security-kms-admin"]'

# Optional: comma-separated GitHub usernames required to approve deploys to this
# environment. Leave unset for a reviewer-free environment (typically dev).
export REQUIRED_REVIEWERS="alice,bob"

# Optional — leave these two unset and scripts/bootstrap-env.sh will propose/create them for
# you interactively when you run it (see steps 5-6 below). Export them here only if you want to
# skip those prompts, e.g. to pre-decide the name yourself or run the script non-interactively.
# export LAKEHOUSE_BUCKET_NAME="..."
# export FLINK_APPLICATION_JAR_S3_BUCKET_ARN="..."
```

Everything else (`MSK_KAFKA_VERSION`, `REDIS_NODE_TYPE`, `FLINK_PARALLELISM`, etc.) is optional
sizing — each falls back to the same default already in `variables.tf` if left commented out. See
`scripts/.env.example` or the usage block at the top of `scripts/bootstrap-env.sh` for the full
list.

## 4b. The KMS key administrator role

`scripts/.env.example`'s `KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS` deserves its own callout — it's the
one required input in step 4 that isn't a tag, a CIDR, or a repo name, and getting it wrong has
real consequences.

**What it controls.** `bootstrap/` creates an IAM role
(`<environment>-nrt-platform-kms-key-admin-breakglass`) that every `global/kms` customer-managed
key's policy grants full administration to: rotate the key, **rewrite the key's own policy**,
and schedule or cancel its deletion. Rewriting a key's policy is the sharp edge — it lets whoever
holds this role grant *themselves* decrypt access to whatever that key protects, not just manage
the key's lifecycle. Every CMK protecting transaction/customer data (MSK, ElastiCache, the
lakehouse) ultimately answers to this role. Treat assuming it like a break-glass credential, not
routine access — see [ADR-0013](architecture-decisions/0013-kms-key-administrator-role.md) for
the full reasoning.

`KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS` is *who's allowed to assume that role* — a JSON list of IAM
principal ARNs (users, roles, or an SSO permission set's role). The role's trust policy also
requires an active MFA session on the caller (`aws:MultiFactorAuthPresent = true`), but that's a
minimum bar, not a substitute for picking the right principal.

**Who this should be, by environment:**

- **dev/PoC**: typically the same privileged identity you're already using to run
  `bootstrap-env.sh`. Fine for unblocking early work — nothing in dev protects real customer
  data.
- **staging/prod**: this **must** be the organization's actual security/governance-team-owned identity —
  never a developer's own role, never anything invented for convenience. If that team doesn't
  exist yet or hasn't been engaged, that engagement is a prerequisite for a real staging/prod
  rollout, not something to work around. Also revisit, at that point, whether the role itself
  should be provisioned and owned by that team's own process instead of `bootstrap/` — ADR-0013
  flags this as open, not resolved.

Never invent a value here, same rule as every other real-organization-identity input in this repo (see
ARCHITECTURE.md, ADR-0001, ADR-0004).

## 5. Choose `LAKEHOUSE_BUCKET_NAME`

**`scripts/bootstrap-env.sh` now does this step for you** if you leave `LAKEHOUSE_BUCKET_NAME`
unset: it proposes `<environment>-nrt-platform-ods-<account-id>`, lets you accept it or type a
different name, and runs the same `head-bucket` availability check shown below. Read on if you
want to pre-decide the name yourself (e.g. to match an existing naming convention) or export it
in step 4 for a non-interactive run — otherwise skip straight to step 7.

This becomes `modules/lakehouse`'s `bucket_name` — Terraform creates the bucket for you during
apply. Your only job is picking a name that's globally unique across *all* of AWS (S3 bucket
names are a single global namespace, not per-account) and unique per environment (dev/staging/
prod each need their own).

Pick something following the convention already used elsewhere in this repo, e.g.:

```
<organization-short-name>-nrt-platform-<environment>-ods
```

Check it's actually free before exporting it — don't create the bucket yourself, just probe:

```bash
aws s3api head-bucket --bucket org-nrt-platform-dev-ods
```

- **404 Not Found** → free, safe to use.
- **403 Forbidden** → already taken by someone else's account; pick another name.
- **200 (no error)** → you already own it (fine, if that's expected — e.g. a prior partial
  bootstrap run already created it).

```bash
export LAKEHOUSE_BUCKET_NAME="org-nrt-platform-dev-ods"
```

## 6. Create the Flink JAR S3 bucket

**`scripts/bootstrap-env.sh` now does this step for you** if you leave
`FLINK_APPLICATION_JAR_S3_BUCKET_ARN` unset: it asks whether you already have a real job JAR to
deploy. If yes, it prompts for the bucket ARN + key and verifies the object actually exists
(`head-object`) before continuing — it does **not** upload anything on your behalf in that case,
you're expected to have staged the real JAR yourself first. If no, it proposes
`<environment>-nrt-platform-flink-jobs-<account-id>`, creates and secures the bucket, and builds
and uploads the same placeholder JAR shown below. Read on if you want to pre-stage a real JAR
before running the script, or export the ARN in step 4 for a non-interactive run — otherwise skip
straight to step 7.

Unlike the lakehouse bucket, `modules/flink-emr` does **not** create this bucket or the JAR
object inside it — `aws_kinesisanalyticsv2_application` just points at an existing S3 location,
and AWS rejects the apply if the object isn't there. You create both by hand, once, before the
first apply for this environment.

```bash
BUCKET="org-nrt-platform-dev-flink-jobs"
REGION="us-east-1"   # match AWS_REGION

aws s3 mb "s3://${BUCKET}" --region "${REGION}"

# Same security posture modules/lakehouse applies to its own bucket — not automatic here since
# no module manages this bucket.
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then upload a placeholder JAR at the key `FLINK_APPLICATION_JAR_S3_KEY` defaults to
(`flink-jobs/bootstrap-noop.jar`) — data engineering hasn't deployed a real job yet, and this
module only stands up the runtime shell (see ARCHITECTURE.md's boundary section), so a trivial
placeholder is what unblocks the first apply:

```bash
mkdir -p /tmp/bootstrap-noop && cd /tmp/bootstrap-noop
echo "placeholder — no real Flink job deployed yet" > README.txt
jar cf bootstrap-noop.jar README.txt   # any JDK's `jar`; `zip` works identically, a JAR is a ZIP

aws s3 cp bootstrap-noop.jar "s3://${BUCKET}/flink-jobs/bootstrap-noop.jar"
```

S3 bucket ARNs don't include region or account ID, so you can construct it directly:

```bash
export FLINK_APPLICATION_JAR_S3_BUCKET_ARN="arn:aws:s3:::${BUCKET}"
```

(Note: this is the **bucket** ARN, not the object ARN — no `/flink-jobs/...` suffix. The object
key is supplied separately via `FLINK_APPLICATION_JAR_S3_KEY`.)

When data engineering has a real job JAR to deploy, they upload it to this same bucket/key (or a
new key + set `FLINK_APPLICATION_JAR_S3_KEY`/`application_jar_s3_object_version` to point at it) —
that's their deploy pipeline's job, not Terraform's.

## 7. Run `scripts/bootstrap-env.sh`

```bash
./scripts/bootstrap-env.sh dev   # or staging / prod
```

What it does, in order (see the script's own header comment for full detail):

0. **Loads `scripts/.env.<environment>`** if it exists (step 4), then **confirms AWS identity**
   (`aws sts get-caller-identity`) and, for whichever of
   `LAKEHOUSE_BUCKET_NAME` / `FLINK_APPLICATION_JAR_S3_BUCKET_ARN` you left unset, resolves it
   interactively — the same defaults, checks, and (for the placeholder JAR path) bucket
   creation described in steps 5-6 above. Already-exported values are used as-is with no prompt.
1. **`terraform plan`** for `bootstrap/` against this environment's own local state file
   (`bootstrap/state/<env>.tfstate`) — shows you every resource to be added/changed.
2. **Pauses for confirmation** — `Apply the plan shown above to the '<environment>' AWS
   account? [y/N]`. Nothing touches AWS before you type `y`.
3. **`terraform apply`** the saved plan (not a fresh re-plan, so what you approved is exactly
   what's applied), then reads back the state bucket name, state KMS key ARN, deploy role ARN,
   and KMS admin role ARN — printing a `CRITICAL` warning banner for the last one (see
   [step 4b](#4b-the-kms-key-administrator-role)).
4. **Creates the GitHub Environment** `<environment>` (with required reviewers, if you set
   `REQUIRED_REVIEWERS`) and a second, always-reviewer-free `<environment>-drift` environment —
   shared by scheduled drift detection (ADR-0011) and scheduled/post-apply operational health
   checks (ADR-0014).
5. **Ensures the `drift` and `health` labels exist** on the repo (creates them if missing).
6. **Sets both GitHub Environments' variables** from everything above plus what you exported —
   `AWS_REGION`, `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN`, `AWS_DEPLOY_ROLE_ARN`,
   `KMS_ADMIN_ROLE_ARNS` (the KMS key administrator role's ARN, see
   [step 4b](#4b-the-kms-key-administrator-role)), the tags, the CIDRs, `LAKEHOUSE_BUCKET_NAME`,
   `FLINK_APPLICATION_JAR_S3_BUCKET_ARN`, and the sizing knobs.

It's safe to re-run for the same environment — every step is idempotent.

Keep `bootstrap/state/<environment>.tfstate` safe (it's gitignored) — back it up somewhere
private outside version control. Without it, `teardown-env.sh` and any future re-run of
`bootstrap-env.sh` for this environment lose track of what already exists.

## 8. What success looks like

The script prints a closing banner:

```
============================================================
 Bootstrap complete for dev!
============================================================

 Next steps:
   1. GitHub -> Actions -> Terraform Plan -> Run workflow -> environment: dev
      (real, authenticated dry-run against this account)
   2. GitHub -> Actions -> Terraform Apply -> Run workflow -> environment: dev
      (plan -> approval gate -> apply, from the saved plan file)
   3. Terraform Drift Detect runs on its own schedule against 'dev-drift';
      trigger it manually any time via GitHub -> Actions -> Terraform Drift Detect.
   4. Operational Health Check runs every 2 hours against 'dev-drift' (also
      runs automatically right after every Terraform Apply); trigger it manually any
      time via GitHub -> Actions -> Operational Health Check.
```

If it stops earlier, it's an explicit `ERROR:` line naming exactly what's missing (a required
env var, a missing CLI tool) — nothing fails silently. Beyond the banner, worth spot-checking:

```bash
# Both GitHub Environments exist
gh api "repos/<owner>/infra-blueprint-NRT-AWS/environments" --jq '.environments[].name'

# Variables landed on the environment
gh variable list --env dev --repo <owner>/infra-blueprint-NRT-AWS

# Terraform actually created the state bucket / OIDC role
terraform -chdir=bootstrap output -state=state/dev.tfstate
```

If you don't have `gh`/AWS access to check from your own machine, a successful
`terraform-plan.yml` run in step 8's own "next steps" (triggered from GitHub Actions) is the
clearest end-to-end confirmation that the OIDC trust, state bucket, and GitHub Environment
variables are all wired correctly.

## 9. Local sanity check (optional)

```bash
cp environments/dev/backend.hcl.example environments/dev/backend.hcl
# edit backend.hcl: bucket + kms_key_id, printed by bootstrap-env.sh in step 7
cd environments/dev
terraform init -backend-config=backend.hcl
terraform validate
```

`backend.hcl` is gitignored — never committed, same treatment as `*.tfvars`. This step is only
useful for a local `terraform validate`/`plan` sanity check; CI never reads it (see step 10).

## 10. Open a PR

Any PR touching `environments/**` or `modules/**` triggers `terraform-validate.yml`'s `validate`
job: `terraform init -backend=false`, `validate`, `fmt -check`, posted as a PR comment. This is
cheap, unauthenticated syntax/lint checking — no AWS credentials or GitHub Environment variables
are touched, so it runs on every PR unconditionally.

To see a **real** diff before merging, manually trigger **Actions -> Terraform Plan -> Run
workflow**, choosing the target environment. That job authenticates via OIDC into that
environment's AWS account and posts a genuine plan to the run's step summary — and is itself
subject to that environment's required-reviewer rule, if one is configured.

## 11. Deploy

Merging to `main` does **not** trigger anything by itself — there is no auto-apply on push (see
ADR-0009). To deploy: **Actions -> Terraform Apply -> Run workflow**, choosing the target
environment. This runs `plan` (authenticate, `terraform plan`, save the plan as an artifact) ->
`approve` (pauses here if that environment has required reviewers) -> `apply` (applies the exact
saved plan file, not a fresh re-plan) -> `health-check` (runs `scripts/health-check.sh` — see
ADR-0014 — against what was just deployed; a read-only smoke test, authenticated through the
same `<environment>-drift` environment as scheduled drift/health checks, so it doesn't need a
second approval).

## Adding staging/prod

Once those AWS accounts exist, repeat steps 1-8 with `./scripts/bootstrap-env.sh staging` /
`./scripts/bootstrap-env.sh prod` (against each account's own credentials, its own
`LAKEHOUSE_BUCKET_NAME`/Flink JAR bucket) — no workflow files to copy or edit;
`terraform-plan.yml`/`terraform-apply.yml` already cover all three environments via the
`workflow_dispatch` environment choice, and `terraform-validate.yml` runs on every PR regardless
of environment. Give `staging`/`prod` a stricter `REQUIRED_REVIEWERS` policy than `dev` at
bootstrap time.

## Tearing down an environment

Two steps, in this order — bootstrap's IAM role/OIDC provider are the only way the Destroy
workflow can authenticate to the account, so tearing bootstrap down first strands whatever's
deployed with no Terraform path left to remove it:

1. **Destroy the deployed infrastructure**: **Actions -> Terraform Destroy -> Run workflow**,
   choosing the target environment and typing its name again into `confirm_environment` (or
   `gh workflow run terraform-destroy.yml -f environment=<env> -f confirm_environment=<env>`).
   Same `plan -> approve -> destroy` shape as Apply — review the destroy plan in the run's step
   summary before approving.
2. **Tear down the bootstrap scaffolding**, from the same machine (and with the same env vars)
   used for that environment's `bootstrap-env.sh` run:
   ```bash
   source scripts/.env.<env>   # or re-export the same vars by hand
   ./scripts/teardown-env.sh <env>
   ```
   Walks through four confirmation gates: a check that step 1 actually ran, destroying
   bootstrap's IAM/OIDC resources, deleting the GitHub Environment, and finally — requiring you
   to type the exact bucket name — deleting the Terraform state bucket itself (this is the one
   irreversible step; everything else can be recreated with `bootstrap-env.sh`).
