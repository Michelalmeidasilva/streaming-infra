variable "enabled" {
  description = "Create the benchmark EC2 instance when true."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type to benchmark (e.g. c7g.xlarge)."
  type        = string
}

variable "machine_label" {
  description = "Label recorded on every transcode run from this instance. Defaults to the instance type."
  type        = string
  default     = ""
}

variable "image_uri" {
  description = "Full ECR image URI for the transcode worker container."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID where the instance is placed."
  type        = string
}

variable "security_group_id" {
  description = "Security group ID to attach to the instance."
  type        = string
}

variable "bucket" {
  description = "S3 bucket name for transcode input/output."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources live."
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the instance (use an Amazon Linux 2023 or compatible AMI)."
  type        = string
}

variable "ssm_parameter_prefix" {
  description = "SSM parameter store prefix (e.g. /vod/prod). Used to read S3 credentials at boot."
  type        = string
}

variable "ssm_parameter_arns" {
  description = "List of SSM parameter ARNs the instance profile must be allowed to read."
  type        = list(string)
}

variable "event_gateway_url" {
  description = "Base URL of the ingest Event Gateway (including /api/v1 suffix)."
  type        = string
}

variable "environment" {
  description = "Deployment environment label (prod, staging, dev)."
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Additional tags to merge onto resources."
  type        = map(string)
  default     = {}
}
