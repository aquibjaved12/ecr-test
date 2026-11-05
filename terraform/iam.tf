# ══════════════════════════════════════════════════════════════════════════════
# Part 1 — EC2 Instance Role
# Grants the instance: SSM connectivity + ECR image pull
# ══════════════════════════════════════════════════════════════════════════════

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

# AWS managed policy — enables SSM Session Manager, Run Command, patch mgmt
resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_ecr_pull" {
  statement {
    sid     = "ECRAuth"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    # GetAuthorizationToken does not support resource-level restrictions
    resources = ["*"]
  }

  statement {
    sid    = "ECRPull"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_policy" "ec2_ecr_pull" {
  name   = "${var.project_name}-ec2-ecr-pull"
  policy = data.aws_iam_policy_document.ec2_ecr_pull.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ec2_ecr_pull" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_ecr_pull.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
  tags = local.common_tags
}

# ══════════════════════════════════════════════════════════════════════════════
# Part 2 — GitHub Actions IAM User
# Grants: ECR push, Inspector SBOM scan, SSM Run Command on this instance
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_user" "github_actions" {
  name = "${var.project_name}-github-actions"
  tags = local.common_tags
}

data "aws_iam_policy_document" "github_actions" {
  # ECR — auth token (account-scoped, no resource restriction allowed)
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR — push to this repository only
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # Inspector — pre-push SBOM scan via the inspector-scan CI/CD API
  # sbomgen generates the SBOM locally; AWS scans it server-side before the image hits ECR
  statement {
    sid       = "InspectorSBOMScan"
    effect    = "Allow"
    actions   = ["inspector-scan:ScanSbom"]
    resources = ["*"]
  }

  # SSM — send commands to this EC2 instance only
  statement {
    sid     = "SSMSendCommand"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.app.arn,
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
    ]
  }

  # SSM — poll command results (GetCommandInvocation has no resource-level support)
  statement {
    sid    = "SSMGetResult"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions" {
  name   = "${var.project_name}-github-actions-policy"
  policy = data.aws_iam_policy_document.github_actions.json
  tags   = local.common_tags
}

resource "aws_iam_user_policy_attachment" "github_actions" {
  user       = aws_iam_user.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

# Access key — credentials are written to Terraform state.
# Run: terraform output -raw github_actions_secret_access_key
# Then store both values as GitHub Actions secrets and remove from state if needed.
resource "aws_iam_access_key" "github_actions" {
  user = aws_iam_user.github_actions.name
}
