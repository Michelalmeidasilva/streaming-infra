locals {
  machine_catalog = {
    "c5.xlarge"   = { arch = "x86_64", gpu = false }
    "c5.2xlarge"  = { arch = "x86_64", gpu = false }
    "c7i.xlarge"  = { arch = "x86_64", gpu = false }
    "c7i.2xlarge" = { arch = "x86_64", gpu = false }
    "c7g.xlarge"  = { arch = "arm64", gpu = false }
    "c8g.xlarge"  = { arch = "arm64", gpu = false }
    "g4dn.xlarge" = { arch = "x86_64", gpu = true }
    "g5.xlarge"   = { arch = "x86_64", gpu = true }
    "g6.xlarge"   = { arch = "x86_64", gpu = true }
    "g6e.xlarge"  = { arch = "x86_64", gpu = true }
  }

  instances = {
    for t in var.benchmark_instance_types : t => {
      arch  = local.machine_catalog[t].arch
      gpu   = local.machine_catalog[t].gpu
      image = local.machine_catalog[t].gpu ? var.ecr_image_gpu : var.ecr_image_cpu
      ami = (
        local.machine_catalog[t].gpu ? data.aws_ami.gpu_x86.id :
        local.machine_catalog[t].arch == "arm64" ? data.aws_ami.al2023_arm.id :
        data.aws_ami.al2023_x86.id
      )
    }
  }
}
