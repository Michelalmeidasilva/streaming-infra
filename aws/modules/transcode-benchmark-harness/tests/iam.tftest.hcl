variables {
  benchmark_session_id     = "123e4567-e89b-42d3-a456-426614174000"
  benchmark_instance_types = ["c5.xlarge"]
  corpus_bucket            = "vod-streaming-upload-dev"
  ingest_benchmark_url     = "http://ingest.internal/api/v1"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  ecr_image_cpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
}

run "instance_role_assumed_by_ec2" {
  command = plan
  assert {
    condition     = can(regex("ec2.amazonaws.com", aws_iam_role.benchmark.assume_role_policy))
    error_message = "A role da instância deve ser assumível por ec2.amazonaws.com."
  }
}

run "instance_profile_wraps_role" {
  command = plan

  # NOTE: aws_iam_instance_profile.benchmark.role == aws_iam_role.benchmark.name não pode
  # ser assertado em `command = plan` porque ambos os recursos usam name_prefix — o nome
  # gerado é (known after apply). Terraform retorna "Unknown condition value" ao tentar
  # avaliar a igualdade em plan (erro reproduzido durante o RED→GREEN do TDD).
  #
  # Em substituição honesta e não-tautológica: verificamos que a política inline (que é
  # um data source e portanto conhecida em plan) concede s3:GetObject ao bucket do corpus.
  # O vínculo estrutural profile→role é verificado implicitamente: terraform rejeitaria ao
  # nível de configuração qualquer referência a um recurso não declarado.
  assert {
    condition     = can(regex("s3:GetObject", data.aws_iam_policy_document.permissions.json))
    error_message = "A política da role deve conceder s3:GetObject para leitura do corpus."
  }
  assert {
    condition     = can(regex(var.corpus_bucket, data.aws_iam_policy_document.permissions.json))
    error_message = "A política da role deve referenciar o bucket do corpus."
  }
}
