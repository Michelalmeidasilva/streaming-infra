resource "aws_security_group" "benchmark" {
  name_prefix = "${var.name_prefix}-sg-"
  description = "Benchmark harness: egress-only, no ingress"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound (ECR, S3, ingest)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "${var.name_prefix}-sg"
    Benchmark = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}
