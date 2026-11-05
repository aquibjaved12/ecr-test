# nginx POC — CI/CD with AWS Inspector, ECR & EC2

A proof-of-concept that demonstrates a secure container delivery pipeline:
build a Docker image → scan it with AWS Inspector **before** pushing to ECR → deploy to EC2 via SSM.

---

## Architecture

```
Developer
   │
   │  git push to main
   ▼
GitHub Actions
   │
   ├─── Job 1: Build → Scan → Push ─────────────────────────────────────┐
   │         │                                                           │
   │    docker build                                                     │
   │         │                                                           │
   │    Syft generates CycloneDX SBOM                                   │
   │    (from local image — ECR not touched yet)                        │
   │         │                                                           │
   │    aws inspector-scan scan-sbom ──► AWS Inspector                  │
   │    (SBOM sent to AWS; image still local)      │                    │
   │         │                                     │ findings           │
   │         ◄─────────────────────────────────────┘                    │
   │         │                                                           │
   │    Vulnerability Gate                                               │
   │    CRITICAL/HIGH/NONE threshold                                     │
   │         │                                                           │
   │    ✗ Fail → pipeline stops, image never reaches ECR               │
   │    ✓ Pass → docker push to ECR                                     │
   │                                                                     │
   └─── Job 2: Deploy to EC2 ───────────────────────────────────────────┘
              │
         aws ssm send-command
              │
         EC2 Instance (i-0882bc93849acc872)
              │
         aws ecr get-login-password | docker login
         docker pull <image>
         docker stop/rm old container
         docker run -p 80:80 --restart unless-stopped
              │
         http://<ec2-public-ip>  ✅
```

---

## Repository Structure

```
├── Dockerfile                          # nginx app container
├── index.html                          # served by nginx
├── .github/
│   └── workflows/
│       └── build-scan-push.yml        # GitHub Actions pipeline
└── terraform/
    ├── versions.tf                     # provider version constraints
    ├── variables.tf                    # input variables
    ├── main.tf                         # provider, locals, data sources
    ├── ec2.tf                          # EC2 instance + security group
    ├── iam.tf                          # EC2 role + GitHub Actions IAM user
    ├── ecr.tf                          # ECR repository + lifecycle policy
    └── outputs.tf                      # instance ID, ECR URL, credentials
```

---

## Infrastructure (Terraform)

All AWS resources are managed by Terraform in the `terraform/` directory.

### Resources created

| Resource | Name | Purpose |
|---|---|---|
| EC2 instance | `testpoc-app` | Runs the nginx container |
| Security group | `testpoc-app-sg` | Port 80 inbound only (no SSH) |
| IAM role | `testpoc-ec2-role` | Attached to EC2 for SSM + ECR pull |
| IAM instance profile | `testpoc-ec2-profile` | Links the role to the instance |
| IAM managed policy attachment | `AmazonSSMManagedInstanceCore` | Enables SSM Session Manager |
| IAM policy | `testpoc-ec2-ecr-pull` | Allows EC2 to pull from ECR |
| IAM user | `testpoc-github-actions` | Used by GitHub Actions |
| IAM policy | `testpoc-github-actions-policy` | ECR push + Inspector scan + SSM deploy |
| ECR repository | `testpoc-app` | Stores Docker images |
| ECR lifecycle policy | — | Keeps last 10 images |

### Key design decisions

- **No port 22** — EC2 is managed entirely via AWS SSM Run Command. No SSH keys needed.
- **IMDSv2 enforced** — `metadata_options.http_tokens = "required"` on the instance.
- **Encrypted root volume** — gp3, 20 GB, encrypted at rest.
- **Least-privilege IAM** — GitHub Actions policy scoped to this ECR repo and this EC2 instance ARN only.

### Commands

```bash
cd terraform

# First time
terraform init
terraform plan
terraform apply

# Get secrets for GitHub
terraform output github_secret_AWS_ACCESS_KEY_ID
terraform output -raw github_secret_AWS_SECRET_ACCESS_KEY
terraform output github_secret_EC2_INSTANCE_ID
terraform output ec2_public_ip
```

---

## CI/CD Pipeline (GitHub Actions)

File: `.github/workflows/build-scan-push.yml`

Triggered on: `push` or `pull_request` to `main`.

### Job 1 — Build → Inspector Scan → Push

| Step | Tool | What happens |
|---|---|---|
| Checkout | `actions/checkout@v4` | Clone the repo |
| Configure AWS | `aws-actions/configure-aws-credentials@v4` | Auth using GitHub secrets |
| Login to ECR | `aws-actions/amazon-ecr-login@v2` | Get ECR auth token |
| Build image | `docker build` | Build locally, tagged with `github.sha` |
| Install Syft | `curl` from GitHub releases | SBOM generator (CycloneDX 1.5) |
| Generate SBOM | `syft … -o cyclonedx-json@1.5` | Extracts packages from local image layers |
| Scan SBOM | `aws inspector-scan scan-sbom` | Sends SBOM to AWS; image still local |
| Upload artifact | `actions/upload-artifact@v4` | Saves `scan-results.json` for 30 days |
| Gate | bash | Fail or pass based on `FAIL_ON_SEVERITY` |
| Push to ECR | `docker push` | Only runs if gate passed, main branch only |

> **Pre-push guarantee:** The image never touches ECR until it passes the gate.
> On a PR, the scan runs but the push step is skipped.

### Job 2 — Deploy to EC2

Runs only on `main` branch after Job 1 succeeds.

| Step | What happens |
|---|---|
| Configure AWS | Re-auth (fresh credentials for deploy job) |
| ECR login | Gets registry URL directly (avoids GitHub's secret-masking of cross-job outputs) |
| SSM send-command | Sends `AWS-RunShellScript` to the EC2 instance |
| Poll status | Checks `GetCommandInvocation` every 5s, up to 2 minutes |
| Show output | Prints SSM stdout/stderr in the Actions log |

**What the SSM script does on EC2:**
```bash
aws ecr get-login-password | docker login --username AWS --password-stdin <registry>
docker pull <image>:<sha>
docker stop testpoc  || true
docker rm   testpoc  || true
docker run -d --name testpoc -p 80:80 --restart unless-stopped <image>:<sha>
docker image prune -f
```

---

## Setup Guide

### Prerequisites

- AWS account with admin access (for first-time Terraform apply)
- Terraform >= 1.5 installed locally
- GitHub repository created
- AWS CLI configured locally (`aws configure`)

### Step 1 — Provision infrastructure

```bash
cd terraform
terraform init
terraform apply
```

**Note:** Terraform enables Inspector v2 for ECR and creates all IAM roles, the EC2 instance, and the ECR repository in one apply.

### Step 2 — Add GitHub secrets

Navigate to: **GitHub repo → Settings → Secrets and variables → Actions**

| Secret name | How to get the value |
|---|---|
| `AWS_ACCESS_KEY_ID` | `terraform output github_secret_AWS_ACCESS_KEY_ID` |
| `AWS_SECRET_ACCESS_KEY` | `terraform output -raw github_secret_AWS_SECRET_ACCESS_KEY` |
| `AWS_REGION` | `terraform output github_secret_AWS_REGION` |
| `EC2_INSTANCE_ID` | `terraform output github_secret_EC2_INSTANCE_ID` |

### Step 3 — Push and trigger the pipeline

```bash
git add .
git commit -m "Initial commit"
git push origin main
```

The push triggers the pipeline automatically. Watch it at:
`https://github.com/<your-username>/<repo-name>/actions`

### Step 4 — Verify the app

```bash
# Get the EC2 public IP
cd terraform && terraform output ec2_public_ip

# Test
curl http://<ec2-public-ip>
```

Or open `http://<ec2-public-ip>` in a browser (HTTP only — no SSL configured).

---

## Configuration Reference

All tunable values are in the `env:` block at the top of `build-scan-push.yml`:

| Variable | Default | Description |
|---|---|---|
| `ECR_REPOSITORY` | `testpoc-app` | Must match the ECR repo name in Terraform (`local.ecr_repository_name`) |
| `CONTAINER_NAME` | `testpoc` | Docker container name on the EC2 instance |
| `FAIL_ON_SEVERITY` | `NONE` | Vulnerability gate threshold (see below) |

### FAIL_ON_SEVERITY values

| Value | Behaviour |
|---|---|
| `NONE` | Scan runs and reports findings; never blocks the push |
| `HIGH` | Blocks if any HIGH-severity CVEs are found |
| `CRITICAL` | Blocks if any CRITICAL-severity CVEs are found |

For production, set to `CRITICAL`. For strict hardening, set to `HIGH`.

### Terraform variables (`terraform/variables.tf`)

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | Must support `inspector-scan` API |
| `project_name` | `testpoc` | Prefix for all resource names and tags |
| `environment` | `poc` | Environment tag applied to all resources |
| `instance_type` | `t3.micro` | EC2 instance type |

---

## Troubleshooting

Issues encountered and resolved during this POC:

| Error | Cause | Fix |
|---|---|---|
| `syntax error near unexpected token 'newline'` on `inspector-sbomgen` | The S3 URL returned an XML error page instead of the binary | Switched to **Syft** (`anchore/syft`) as the SBOM generator |
| `ValidationException: Unsupported specVersion` | Syft defaults to CycloneDX 1.4; Inspector requires 1.5+ | Added `@1.5` version specifier: `syft … -o cyclonedx-json@1.5` |
| `malformed HTTP Authorization header` on docker pull (Docker Hub URL in error) | GitHub Actions masked cross-job outputs containing the AWS account ID | Re-login to ECR directly in the deploy job; build image URL from `steps.login-ecr.outputs.registry` |
| `BLOCKED: N critical vulnerabilities found` | `nginx:alpine` / `nginx:1.27-alpine` carry many Alpine OS CVEs | Set `FAIL_ON_SEVERITY: NONE` for the POC demo (gate still scans and reports) |
| Site not loading in browser | Browser auto-upgraded to HTTPS | Use `http://` explicitly — no TLS configured in this POC |

---

## IAM Permissions Reference

### GitHub Actions IAM user policy

```json
{
  "ecr:GetAuthorizationToken": "*",
  "ecr:BatchCheckLayerAvailability, GetDownloadUrlForLayer, BatchGetImage,
   InitiateLayerUpload, UploadLayerPart, CompleteLayerUpload, PutImage": "<ecr-repo-arn>",
  "inspector-scan:ScanSbom": "*",
  "ssm:SendCommand": ["<ec2-instance-arn>", "arn:aws:ssm:<region>::document/AWS-RunShellScript"],
  "ssm:GetCommandInvocation, DescribeInstanceInformation": "*"
}
```

### EC2 instance profile

| Policy | Type | Purpose |
|---|---|---|
| `AmazonSSMManagedInstanceCore` | AWS managed | SSM Session Manager, Run Command |
| `testpoc-ec2-ecr-pull` | Custom inline | Pull images from the ECR repository |

---

## Live Environment

| Resource | Value |
|---|---|
| EC2 public IP | `3.87.59.234` |
| EC2 instance ID | `i-0882bc93849acc872` |
| ECR repository | `183295435445.dkr.ecr.us-east-1.amazonaws.com/testpoc-app` |
| AWS region | `us-east-1` |
| App URL | `http://3.87.59.234` |
