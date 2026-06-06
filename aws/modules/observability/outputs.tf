output "dashboard_name" {
  description = "Name of the CloudWatch Golden Signals dashboard."
  value       = aws_cloudwatch_dashboard.golden_signals.dashboard_name
}
