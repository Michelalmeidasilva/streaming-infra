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
}
