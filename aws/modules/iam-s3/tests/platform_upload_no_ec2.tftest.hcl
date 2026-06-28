# Prova: a identidade IAM do platform-upload (módulo iam-s3, usuário vod-storage-svc)
# NÃO possui permissões de EC2 em nenhuma forma, satisfazendo o requisito §4 da spec:
# "platform-upload identity must hold ONLY lambda:InvokeFunctionUrl on the orchestrator
# function — NEVER EC2 permissions".
#
# EXPLORAÇÃO (Task 7 + Task 7 fix-invoke): o módulo iam-s3 cria UMA única policy inline
# no usuário (`aws_iam_user_policy.s3_access`), gerada a partir de
# `data.aws_iam_policy_document.s3_access`. A concessão de lambda:InvokeFunctionUrl é
# injetada como segunda policy inline NO NÍVEL RAIZ (aws_iam_user_policy.benchmark_invoke,
# count-gated), portanto este módulo continua com política exclusivamente S3.
#
# ASSUNÇÃO DE SINGLE-POLICY: dentro deste módulo há apenas um `aws_iam_user_policy`
# (`s3_access`). A asserção contra `data.aws_iam_policy_document.s3_access.json` cobre
# integralmente o documento — `aws_iam_user_policy.s3_access.policy` é o mesmo JSON
# renderizado. Adicionamos a asserção redundante no run "platform_upload_cannot_run_ec2"
# para capturar qualquer discrepância futura entre o documento e a resource efetivada.
#
# RED reasoning:
# - run "platform_upload_cannot_run_ec2": falharia imediatamente se qualquer ação "ec2:*"
#   fosse adicionada ao bloco `actions` em main.tf (checado no doc E na resource efetivada).
# - run "platform_upload_policy_is_s3_only": falharia se o SID ou s3:PutObject fossem
#   removidos, indicando deriva na política mínima esperada.

variables {
  bucket_arn = "arn:aws:s3:::vod-streaming-upload-dev"
}

run "platform_upload_cannot_run_ec2" {
  command = plan

  assert {
    condition     = !can(regex("ec2:", data.aws_iam_policy_document.s3_access.json))
    error_message = "A policy do platform-upload NÃO pode conter permissões EC2 (ec2:*) — policy document."
  }

  # Asserção redundante contra a resource efetivada (aws_iam_user_policy.s3_access.policy).
  # Garante que não há discrepância futura entre o doc fonte e o JSON aplicado ao usuário.
  assert {
    condition     = !can(regex("ec2:", aws_iam_user_policy.s3_access.policy))
    error_message = "A policy inline efetivada no usuário NÃO pode conter permissões EC2 (ec2:*)."
  }
}

run "platform_upload_policy_is_s3_only" {
  command = plan

  assert {
    condition     = can(regex("s3:PutObject", data.aws_iam_policy_document.s3_access.json))
    error_message = "A policy do platform-upload deve conter s3:PutObject."
  }

  assert {
    condition     = can(regex("AllowS3Actions", data.aws_iam_policy_document.s3_access.json))
    error_message = "A policy do platform-upload deve ter o SID AllowS3Actions (política mínima esperada)."
  }
}
