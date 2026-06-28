output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "killswitch_topic_arn" {
  value = aws_sns_topic.killswitch.arn
}

output "killswitch_function_name" {
  value = aws_lambda_function.killswitch.function_name
}
