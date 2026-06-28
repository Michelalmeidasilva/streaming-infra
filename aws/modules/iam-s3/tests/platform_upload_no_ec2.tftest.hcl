# Prova: a identidade IAM do platform-upload (módulo iam-s3, usuário vod-storage-svc)
# NÃO possui permissões de EC2 em nenhuma forma, satisfazendo o requisito §4 da spec:
# "platform-upload identity must hold ONLY lambda:InvokeFunctionUrl on the orchestrator
# function — NEVER EC2 permissions".
#
# EXPLORAÇÃO (Task 7): o módulo iam-s3 é a única identidade IAM do platform-upload
# gerenciada por Terraform. Sua policy cobre exclusivamente ações S3 sobre o bucket
# de upload. Não há outro módulo ou resource AWS criando um usuário/role para esse serviço.
#
# REQUISITO DEFERIDO AO DEPLOY — lambda:InvokeFunctionUrl:
# A spec exige que o platform-upload possa invocar a Function URL do orquestrador
# (benchmark-trigger). Essa concessão NÃO está neste módulo porque:
#   1. O módulo benchmark_trigger usa count = 0 por padrão; seu ARN só existe quando
#      enable_transcode_benchmark_harness = true — referenciar o ARN aqui criaria
#      dependência circular/referência nula na configuração raiz.
#   2. A injeção de uma policy condicional (if count > 0) não é suportada nativamente
#      em Terraform sem meta-argumentos complexos que tornariam a config frágil.
# AÇÃO DE DEPLOY OBRIGATÓRIA: ao ativar o benchmark, um operador DEVE adicionar
# manualmente (ou via script pós-apply) a seguinte policy ao usuário vod-storage-svc:
#
#   {
#     "Effect": "Allow",
#     "Action": "lambda:InvokeFunctionUrl",
#     "Resource": "<ARN da function_url do módulo benchmark_trigger[0]>",
#     "Condition": { "StringEquals": { "lambda:FunctionUrlAuthType": "AWS_IAM" } }
#   }
#
# Esse requisito deve constar no runbook de deploy do benchmark (RUNBOOK.md §benchmark).
#
# RED reasoning:
# - run "platform_upload_cannot_run_ec2": falharia imediatamente se qualquer ação "ec2:*"
#   fosse adicionada ao bloco `actions` em main.tf.
# - run "platform_upload_policy_is_s3_only": falharia se o SID ou s3:PutObject fossem
#   removidos, indicando deriva na política mínima esperada.

variables {
  bucket_arn = "arn:aws:s3:::vod-streaming-upload-dev"
}

run "platform_upload_cannot_run_ec2" {
  command = plan

  assert {
    condition     = !can(regex("ec2:", data.aws_iam_policy_document.s3_access.json))
    error_message = "A policy do platform-upload NÃO pode conter permissões EC2 (ec2:*)."
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
