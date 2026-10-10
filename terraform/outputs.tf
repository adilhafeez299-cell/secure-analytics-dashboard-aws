output "dashboard_url" {
  description = "Open this in your browser (accept the self-signed certificate warning)."
  value       = "https://${aws_lb.main.dns_name}"
}

output "entra_redirect_uri" {
  description = "Add this as a Web redirect URI on the Entra app registration."
  value       = "https://${aws_lb.main.dns_name}/oauth2/idpresponse"
}

output "ecr_repository_url" {
  description = "Push the container image here."
  value       = aws_ecr_repository.app.repository_url
}

output "secret_id" {
  description = "Secrets Manager secret to put the Entra client secret into."
  value       = aws_secretsmanager_secret.oidc.id
}

output "asg_name" {
  description = "Auto Scaling Group name (for finding the instance)."
  value       = aws_autoscaling_group.app.name
}

output "rocky_ami" {
  description = "The Rocky Linux image actually used."
  value       = "${data.aws_ami.rocky.name} (${data.aws_ami.rocky.id})"
}
