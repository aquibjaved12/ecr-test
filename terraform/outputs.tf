# ── GitHub Actions secrets ─────────────────────────────────────────────────
# Copy these values into your GitHub repository secrets.

output "github_secret_AWS_ACCESS_KEY_ID" {
  description = "Set as GitHub secret: AWS_ACCESS_KEY_ID"
  value       = aws_iam_access_key.github_actions.id
}

output "github_secret_AWS_SECRET_ACCESS_KEY" {
  description = "Set as GitHub secret: AWS_SECRET_ACCESS_KEY  |  terraform output -raw github_secret_AWS_SECRET_ACCESS_KEY"
  value       = aws_iam_access_key.github_actions.secret
  sensitive   = true
}

output "github_secret_AWS_REGION" {
  description = "Set as GitHub secret: AWS_REGION"
  value       = var.aws_region
}

output "github_secret_EC2_INSTANCE_ID" {
  description = "Set as GitHub secret: EC2_INSTANCE_ID"
  value       = aws_instance.app.id
}

# ── Informational ───────────────────────────────────────────────────────────

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance — visit http://<ip> after first deploy"
  value       = aws_instance.app.public_ip
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}
