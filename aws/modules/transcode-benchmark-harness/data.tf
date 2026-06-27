# AL2023 x86_64 (CPU)
data "aws_ami" "al2023_x86" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# AL2023 arm64 (Graviton CPU)
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# GPU: AMI com driver NVIDIA + Docker (ECS GPU optimized, x86_64)
# EXCEÇÃO DELIBERADA: usa Amazon Linux 2 (amzn2-ami-ecs-gpu-hvm-*) em vez de AL2023.
# AMIs ECS GPU com driver NVIDIA são significativamente mais escassas no catálogo AL2023;
# a nomenclatura também difere, tornando o filtro genérico menos confiável.
# TODO: migrar para AL2023 quando uma AMI ECS GPU estável for disponibilizada pela Amazon.
data "aws_ami" "gpu_x86" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-gpu-hvm-*-x86_64-ebs"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
