variable "enabled" {
  description = "Create the benchmark harness EC2 instance when true."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type to benchmark (e.g. c5.xlarge for x86_64, c7g.xlarge for arm64). Used when instance_types is empty (single-instance / compat mode)."
  type        = string
  default     = ""
}

variable "instance_types" {
  description = "Frota: se não-vazio, lança uma instância por tipo; senão usa instance_type (compat). Default [] preserva modo single-instance."
  type        = list(string)
  default     = []
}

variable "ami_arch" {
  description = "CPU architecture for the AMI lookup: x86_64 or arm64."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_arch)
    error_message = "ami_arch must be x86_64 or arm64."
  }
}

variable "machine_label" {
  description = "Optional label passed to the benchmark container. When empty, the container reads IMDS."
  type        = string
  default     = ""
}

variable "image_uri" {
  description = "Full ECR image URI for the transcode container (registry/repo:tag)."
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

variable "aws_region" {
  description = "AWS region where resources live."
  type        = string
}

variable "corpus_bucket" {
  description = "S3 bucket name that holds the benchmark corpus clips."
  type        = string
}

variable "corpus_prefix" {
  description = "S3 key prefix where corpus clips are stored (e.g. benchmark/corpus/)."
  type        = string
}

variable "codecs" {
  description = "Comma-separated codec list for the benchmark matrix (e.g. h264,h265,av1)."
  type        = string
}

variable "resolutions" {
  description = "Comma-separated WxH:bitrate pairs for the benchmark resolution ladder."
  type        = string
}

variable "repeats" {
  description = "Number of re-encode repetitions per corpus clip / codec / resolution."
  type        = number
}

variable "ingest_benchmark_url" {
  description = "Base URL of the ingest Event Gateway to post benchmark results (including /api/v1 suffix)."
  type        = string
}

variable "ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix (e.g. /vod/prod). Used to read S3 credentials at boot."
  type        = string
}

variable "ssm_parameter_arns" {
  description = "List of SSM parameter ARNs the instance profile must be allowed to read."
  type        = list(string)
}

variable "tags" {
  description = "Additional tags to merge onto resources."
  type        = map(string)
  default     = {}
}

variable "gpu" {
  description = "When true, launch a GPU instance from the NVIDIA Deep Learning AMI and run the container with --gpus all."
  type        = bool
  default     = false
}

variable "gpu_ami_name_filter" {
  description = "Name filter for the NVIDIA-driver AMI used when gpu=true (arch-matched by the data source)."
  type        = string
  default     = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"
}

variable "encoder_backend" {
  description = "Encoder backend passed to the container as TRANSCODE_ENCODER_BACKEND (software or nvenc)."
  type        = string
  default     = "software"
}

variable "benchmark_mode" {
  description = "throughput (default) or rd (rate-distortion quality sweep)."
  type        = string
  default     = "throughput"
}

variable "quality_points" {
  description = "Per-codec CRF/CQ lists for rd mode, e.g. h264=19,25,31;av1=20,40,55."
  type        = string
  default     = ""
}
