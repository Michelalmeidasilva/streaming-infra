resource "aws_lambda_function" "orchestrator" {
  function_name = var.name_prefix
  role          = aws_iam_role.orchestrator.arn
  package_type  = "Image"
  image_uri     = var.image_uri
  timeout       = 900
  memory_size   = 1024

  environment {
    variables = {
      MAX_CONCURRENT_INSTANCES = "8"
      TF_IN_AUTOMATION         = "1"
    }
  }
}

resource "aws_lambda_function_url" "orchestrator" {
  function_name      = aws_lambda_function.orchestrator.function_name
  authorization_type = "AWS_IAM"
}
