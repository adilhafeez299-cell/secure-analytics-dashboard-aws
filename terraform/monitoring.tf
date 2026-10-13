# ---------- logs kept off the server ----------
# The app's audit trail (who did what, when) must survive the server being
# replaced, so the CloudWatch agent ships it here. Retention is a client
# decision; 90 days for the demo.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/app-audit"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/${var.project}/bootstrap"
  retention_in_days = 14
}

# VPC Flow Logs: network evidence of what talked to what.
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.project}/vpc-flow"
  retention_in_days = 30
}

resource "aws_iam_role" "flow" {
  name = "${var.project}-vpc-flow"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  name = "write-flow-logs"
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow.arn
}

# ---------- alerts ----------
# Alerts go to email. Confirm the subscription email AWS sends you.
# Not KMS-encrypted on purpose: CloudWatch alarms cannot publish to a topic
# encrypted with the AWS-managed SNS key. Alerts carry no data. Production:
# a customer key whose policy allows cloudwatch.amazonaws.com.
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dims = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

# The app is down: no healthy server behind the load balancer.
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${var.project}-no-healthy-hosts"
  alarm_description   = "No healthy app server. Users cannot reach the dashboard."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.alb_dims
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# The app is returning errors.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.project}-app-5xx"
  alarm_description   = "The app returned 5 or more server errors in 5 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.alb_dims
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# The app is slow.
resource "aws_cloudwatch_metric_alarm" "slow" {
  alarm_name          = "${var.project}-slow-responses"
  alarm_description   = "90th percentile response time above 2 seconds for 10 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dims
  extended_statistic  = "p90"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# The server is working too hard.
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.project}-cpu-high"
  alarm_description   = "Average CPU above 80% for 10 minutes. Time to scale out or size up."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
