variable "aws_region" {
  description = "AWS region — must support the inspector-scan API (us-east-1, us-west-2, eu-west-1)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Used as a prefix for all resource names and tags"
  type        = string
  default     = "testpoc"
}

variable "environment" {
  description = "Environment label applied to all tags"
  type        = string
  default     = "poc"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}
