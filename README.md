# nginx-poc

A sample nginx app for POC purposes. The GitHub Actions pipeline builds the Docker image, scans it with **AWS Inspector** (pre-push), pushes to **Amazon ECR**, and deploys to an **EC2 instance** — all automatically on merge to `main`.

## Pipeline Flow

```
git push to main
       │
       ▼
  Build Docker image
       │
       ▼
  Generate SBOM (inspector-sbomgen)
       │
       ▼
  AWS Inspector Scan  ◄─── scan-results.json artifact
       │
  ┌────▼────┐
  │  Gate   │  FAIL if Critical (or High) CVEs found
  └────┬────┘
       │ pass
       ▼
  Push to ECR  (SHA tag + latest)
       │
       ▼
  Deploy to EC2 via SSM
  - docker pull from ECR
  - replace running container
```

Pull requests run Build → Scan → Gate but **do not push or deploy**.

---

## One-time Setup

### 1. Create ECR Repository

```bash
aws ecr create-repository \
  --repository-name nginx-poc-app \
  --region <your-region>
```

### 2. EC2 Instance Requirements

The EC2 instance needs:

- **Docker** installed (see user data script below)
- **SSM Agent** running (pre-installed on Amazon Linux 2 / Ubuntu 20.04+)
- **IAM Instance Profile** attached with the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:*",
      "Resource": "*"
    }
  ]
}
```

**EC2 User Data** (Amazon Linux 2 — installs Docker on first boot):

```bash
#!/bin/bash
yum update -y
yum install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user
```

**EC2 User Data** (Ubuntu):

```bash
#!/bin/bash
apt-get update -y
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu
```

### 3. IAM Permissions for GitHub Actions

The IAM user used by GitHub Actions needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "inspector-scan:ScanSbom",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:DescribeInstanceInformation"
      ],
      "Resource": "*"
    }
  ]
}
```

### 4. GitHub Secrets

Add these in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user access key ID |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret access key |
| `AWS_REGION` | AWS region, e.g. `us-east-1` |
| `EC2_INSTANCE_ID` | Target EC2 instance ID, e.g. `i-0abc123def456` |

> **Region note:** The `inspector-scan` API is not available in every region.  
> Safe choices: `us-east-1`, `us-west-2`, `eu-west-1`.

---

## Configuration

Edit `.github/workflows/build-scan-push.yml` env block:

| Variable | Default | Description |
|----------|---------|-------------|
| `ECR_REPOSITORY` | `nginx-poc-app` | ECR repository name |
| `CONTAINER_NAME` | `nginx-poc` | Docker container name on EC2 |
| `FAIL_ON_SEVERITY` | `CRITICAL` | Set to `HIGH` to also block high-severity findings |

---

## Local Testing

```bash
docker build -t nginx-poc .
docker run -p 8080:80 nginx-poc
# Visit http://localhost:8080
```
