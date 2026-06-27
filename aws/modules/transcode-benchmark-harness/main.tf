resource "aws_instance" "benchmark" {
  for_each = local.instances

  ami                                  = each.value.ami
  instance_type                        = each.key
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [aws_security_group.benchmark.id]
  iam_instance_profile                 = aws_iam_instance_profile.benchmark.name
  instance_initiated_shutdown_behavior = "terminate"
  user_data                            = local.user_data[each.key]

  metadata_options {
    http_tokens   = "required" # IMDSv2 obrigatório (machine label via IMDSv2)
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name         = "${var.name_prefix}-${each.key}"
    Benchmark    = "true"
    SessionId    = var.benchmark_session_id
    MachineLabel = each.key
  }
}
