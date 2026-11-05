# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A sample nginx POC app with a GitHub Actions pipeline: build → AWS Inspector scan → push to ECR → deploy to EC2.

## Pipeline (`build-scan-push.yml`)

Two jobs, both only fully execute on pushes to `main`:

**Job 1 — `build-scan-push`**
1. Build Docker image tagged with `github.sha`
2. Download `inspector-sbomgen`, generate CycloneDX SBOM from the local image
3. Call `aws inspector-scan scan-sbom` → `scan-results.json`
4. Enforce vulnerability gate (`FAIL_ON_SEVERITY` env var: `CRITICAL` or `HIGH`)
5. Push SHA-tagged + `latest` to ECR
6. Outputs: `image` (full ECR URI) and `registry` (for use by job 2)

**Job 2 — `deploy`** (`needs: build-scan-push`)
1. Sends an `AWS-RunShellScript` SSM command to `EC2_INSTANCE_ID`
2. Script: ECR login → docker pull → stop/rm old container → docker run → image prune
3. Polls `get-command-invocation` until Success/Failed (2-minute timeout)

## Key Configuration

- `ECR_REPOSITORY`, `CONTAINER_NAME`, and `FAIL_ON_SEVERITY` are `env:` vars at the top of the workflow — the only values that need changing per environment.
- The `inspector-scan` API is a separate AWS service namespace from Inspector v2; IAM action needed: `inspector-scan:ScanSbom`.
- Deployment uses SSM (no SSH, no port 22); EC2 instance needs the `AmazonSSMManagedInstanceCore` policy and Docker installed.
- Required GitHub secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `EC2_INSTANCE_ID`.

## Local Testing

```powershell
docker build -t nginx-poc .
docker run -p 8080:80 nginx-poc
# Visit http://localhost:8080
```
