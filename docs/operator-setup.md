# Operator setup: getting your workstation ready

This is the layer beneath [deployment.md](deployment.md) — get your machine and accounts ready
once, then follow deployment.md for the actual bootstrap/plan/apply sequence. Read this if
you're setting up to run `scripts/bootstrap-env.sh` or trigger the Terraform workflows for the
first time. See [ADR-0009](architecture-decisions/0009-environment-scoped-oidc-manual-cicd.md)
for why the tooling is shaped this way.

## 1. Install the tooling

| Tool | Why | macOS (Homebrew) |
|---|---|---|
| Terraform >= 1.10 | Runs `bootstrap/` and `environments/*` locally; S3 native state locking (`use_lockfile`) needs >= 1.10 | `brew install terraform` |
| AWS CLI v2 | Your own credentials for the one-time bootstrap apply | `brew install awscli` |
| GitHub CLI (`gh`) | Creates/configures GitHub Environments and their variables — `bootstrap-env.sh` shells out to it | `brew install gh` |
| `jq` | Builds the JSON `bootstrap-env.sh` sends to the GitHub API | `brew install jq` |
| `zip` | Only needed if you let `bootstrap-env.sh` build the placeholder Flink JAR interactively (see step 4) | usually preinstalled on macOS/Linux |

Confirm versions:

```bash
terraform version
aws --version
gh --version
jq --version
```

## 2. Authenticate

**AWS** — to whichever account you're bootstrapping (dev/staging/prod are separate accounts,
so you'll do this once per environment, not once total):

```bash
aws sso login --profile <profile>   # or: export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
aws sts get-caller-identity          # confirms you're in the right account before anything else
```

This is the *only* time human AWS credentials touch the account. `bootstrap-env.sh` creates the
OIDC trust that lets GitHub Actions take over from here — no long-lived AWS keys ever get
stored anywhere.

**GitHub**:

```bash
gh auth login
gh auth status
```

You need admin (or maintain) access on this repo — creating a GitHub Environment and setting
its required-reviewers policy via the API (`gh api .../environments/<name>`) requires it. A
`gh auth status` that only shows `repo`/`read:org` scopes without repo-admin rights will fail at
the "create GitHub Environment" step with a 403/404 — that's the tell if it happens.

## 3. Clone the repo and check the layout

```bash
git clone <this repo>
cd infra-blueprint-NRT-AWS
```

The pieces that matter for this doc:

- `bootstrap/` — Terraform for the one-time, per-AWS-account state bucket + OIDC trust
- `scripts/bootstrap-env.sh` — wraps `bootstrap/` + GitHub Environment setup into one script
- `environments/{dev,staging,prod}/` — the actual infrastructure, one directory per environment
- `.github/workflows/terraform-{plan,apply}.yml` — the CI/CD that reads what `bootstrap-env.sh`
  wrote

## 4. What `scripts/bootstrap-env.sh` actually does

Run once per environment (i.e. once per AWS account), from your machine, with AWS credentials
for that account active and `gh` authenticated:

```bash
./scripts/bootstrap-env.sh dev|staging|prod
```

It reads these from `scripts/.env.<environment>` — copy `scripts/.env.example` to
`scripts/.env.dev` (or `staging`/`prod`), fill it in, and the script auto-loads it, no manual
`source` needed (same idea as `terraform.tfvars`; see [deployment.md](deployment.md) step 4 for
the worked example). Exporting the same variables in your shell instead still works with no file
present. The two marked "optional" below are the exception either way: leave them unset and the
script resolves them interactively instead of erroring out:

| Variable | Meaning |
|---|---|
| `GITHUB_REPO` | `owner/repo` — where the OIDC trust and GitHub Environment get created |
| `AWS_REGION` | Region for the state bucket, KMS key, and everything in `environments/<env>` |
| `COST_CENTER`, `DATA_CLASSIFICATION`, `OWNER`, `RETENTION_POLICY` | The organization's mandatory tags (`global/tagging-policy.tf`) |
| `NETWORK_SHARED_VPC_CIDR`, `INTEGRATION_VPC_CIDR`, `NRT_PROCESSING_VPC_CIDR`, `DATA_VPC_CIDR` | One non-overlapping CIDR per boundary account (see ADR-0004) |
| `*_PRIVATE_SUBNET_CIDRS` | JSON list of subnet CIDRs per boundary, one per AZ |
| `KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS` | JSON list of IAM principal ARNs trusted to assume the MFA-gated KMS key administrator role `bootstrap/` creates — see [deployment.md §4b](deployment.md#4b-the-kms-key-administrator-role) |
| `REQUIRED_REVIEWERS` (optional) | Comma-separated GitHub usernames who must approve deploys to this environment — leave unset for no gate (typically `dev`) |
| `LAKEHOUSE_BUCKET_NAME` (optional) | Name for the ODS bucket Terraform will create — must be globally unique. Leave unset and the script proposes/checks one interactively; see [deployment.md](deployment.md#5-choose-lakehouse_bucket_name) |
| `FLINK_APPLICATION_JAR_S3_BUCKET_ARN` (optional) | ARN of a bucket holding the Flink application JAR at `FLINK_APPLICATION_JAR_S3_KEY` — Terraform doesn't create this one. Leave unset and the script asks whether you have a real JAR or want it to provision a placeholder; see [deployment.md](deployment.md#6-create-the-flink-jar-s3-bucket) |

In short: it applies `bootstrap/` for that environment (its own local state file at
`bootstrap/state/<env>.tfstate`) — creating the state S3 bucket, its KMS key, the GitHub OIDC
provider, a deploy IAM role trusted only for `repo:<repo>:environment:<env>`, and an MFA-gated
KMS key administrator role trusted only by `KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS` (see
[deployment.md §4b](deployment.md#4b-the-kms-key-administrator-role)) — then creates the matching
GitHub Environment (with a required-reviewers rule if `REQUIRED_REVIEWERS` was set) and sets its
variables (`AWS_REGION`, `TF_STATE_BUCKET`, `TF_STATE_KMS_KEY_ARN`, `AWS_DEPLOY_ROLE_ARN`,
`KMS_ADMIN_ROLE_ARNS`, the tags, the CIDRs — no secrets, since role ARNs and region aren't
sensitive on their own). It's safe to re-run for the same environment — every step is idempotent.

See [deployment.md §7](deployment.md#7-run-scriptsbootstrap-envsh) for the full step-by-step as
you'll actually see it run, including the two interactive bucket/JAR prompts and the
`<environment>-drift` GitHub Environment it also creates (ADR-0011).

## 5. Triggering the workflows

Once `bootstrap-env.sh` has run for an environment, everything else happens in GitHub Actions,
either from the web UI or `gh` CLI:

```bash
# Real, authenticated dry-run against one environment's live state
gh workflow run terraform-plan.yml -f environment=dev
gh run watch                # follow it; the plan lands in the run's step summary

# Full deploy: plan -> approval gate (if that environment has required reviewers) -> apply
gh workflow run terraform-apply.yml -f environment=dev
gh run watch
```

If the environment has `REQUIRED_REVIEWERS` set, the run pauses at the `approve` job — approve
it either in the run's page under "Review deployments" or with:

```bash
gh api --method POST \
  repos/<owner>/<repo>/actions/runs/<run-id>/pending_deployments \
  -f environment_ids[]=<environment-id> -f state=approved -f comment="reviewed, looks good"
```

(the web UI's "Review deployments" button does the same thing, and is usually simpler than
hunting down the numeric environment id).

## 6. Day-to-day: making an infrastructure change

See [deployment.md steps 10-11](deployment.md#10-open-a-pr) for the PR -> validate -> plan ->
merge -> apply cycle. Step 5 above is the `gh` CLI equivalent of the "trigger
`terraform-plan.yml`/`terraform-apply.yml` manually" parts of that cycle, if you'd rather not use
the GitHub Actions web UI.

## Troubleshooting

- **`bootstrap-env.sh` fails immediately at "Checking AWS identity..."** — your AWS credentials
  aren't active (expired SSO session, wrong/missing profile). Re-run `aws sts get-caller-identity`
  (step 2) until it succeeds, then re-run the script — this check runs before anything else,
  including the interactive bucket/JAR prompts, so nothing is left half-configured.
- **`bootstrap-env.sh` fails at the GitHub Environment step with 403/404** — you likely don't
  have admin/maintain access on the repo, or `gh auth login` didn't grant a scope with
  environment-management rights. Re-check `gh auth status`.
- **`terraform-plan.yml`/`terraform-apply.yml` fail at "Configure AWS credentials (OIDC)"** — the
  environment name passed to the workflow doesn't match what `bootstrap-env.sh` was run with, or
  `bootstrap-env.sh` was never run for that environment/account. The trust condition is an exact
  match on `repo:<repo>:environment:<name>` (ADR-0009) — no partial matches.
- **`REQUIRED_REVIEWERS` lookup fails** — `bootstrap-env.sh` resolves each username via
  `gh api users/<name>`; a typo'd or non-existent username fails here before anything else runs.
- **`teardown-env.sh` fails with "state file not found"** — its `bootstrap/state/<env>.tfstate`
  is gitignored and local-only; run the script from whichever machine originally ran
  `bootstrap-env.sh` for that environment, not a fresh clone.
- **`teardown-env.sh`'s confirmation prompts** — the `destroyed` prompt (step 1) is a manual
  attestation that `terraform-destroy.yml` already finished for that environment, since the
  script's own check only reads a state file, not live AWS reality. The bucket-name prompt
  (step 4) requires typing the exact state bucket name — deliberately harder to fat-finger than
  `y/N`, since that step bypasses Terraform's own `prevent_destroy` guard and is the one
  genuinely irreversible action in the whole teardown.
