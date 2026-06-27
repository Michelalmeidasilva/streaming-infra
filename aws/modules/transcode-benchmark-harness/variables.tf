variable "benchmark_instance_types" {
  type        = list(string)
  description = "Tipos de instância EC2 a lançar (uma instância por tipo)."

  validation {
    condition     = length(var.benchmark_instance_types) > 0
    error_message = "Informe ao menos um tipo de instância."
  }

  validation {
    condition = alltrue([
      for t in var.benchmark_instance_types : contains(keys(local.machine_catalog), t)
    ])
    error_message = "Todos os tipos devem existir no catálogo de máquinas suportadas (locals.tf)."
  }

  validation {
    condition     = length(var.benchmark_instance_types) <= var.max_concurrent_instances
    error_message = "Quantidade de tipos excede max_concurrent_instances."
  }
}

variable "max_concurrent_instances" {
  type        = number
  default     = 8
  description = "Teto de instâncias simultâneas por run."
}

variable "benchmark_session_id" {
  type        = string
  description = "UUID que correlaciona o run (vira tag e env BENCHMARK_SESSION_ID)."
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.benchmark_session_id))
    error_message = "benchmark_session_id deve ser um UUID."
  }
}

variable "codecs" {
  type    = list(string)
  default = ["h264"]
}

variable "resolutions" {
  type    = string
  default = "1280x720:2800,1920x1080:5000"
}

variable "repeats" {
  type    = number
  default = 3
}

variable "mode" {
  type    = string
  default = "throughput"
  validation {
    condition     = contains(["throughput", "rd"], var.mode)
    error_message = "mode deve ser 'throughput' ou 'rd'."
  }
}

variable "corpus_bucket" {
  type = string
}

variable "corpus_prefix" {
  type    = string
  default = "benchmark/corpus/"
}

variable "ingest_benchmark_url" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ecr_image_cpu" {
  type = string
}

variable "ecr_image_gpu" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "vod-bench"
}
