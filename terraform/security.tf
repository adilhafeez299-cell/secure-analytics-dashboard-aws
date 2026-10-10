# ---------- encryption key ----------
# Customer-managed KMS key: we control who can use it, and every use is
# logged in CloudTrail. Used here for the OIDC client secret.
# (EBS uses the AWS-managed aws/ebs key: a customer key on an Auto Scaling
# Group also needs a key-policy grant for the Auto Scaling service role.)
resource "aws_kms_key" "main" {
  description             = "${var.project} secrets key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------- the vault: Secrets Manager ----------
# Terraform creates the empty secret. YOU put the value in with the AWS CLI
# (runbook step), so the client secret never appears in code or git.
resource "aws_secretsmanager_secret" "oidc" {
  name                    = "${var.project}/entra-client-secret"
  description             = "Entra ID app registration client secret, used by the load balancer"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0 # demo: delete immediately on destroy
}

# Read at apply time to configure the listener. Any plan fails until the
# secret has a value (runbook step 5). Note: the value then sits
# in Terraform state, which is why real state lives in encrypted S3.
data "aws_secretsmanager_secret_version" "oidc" {
  secret_id = aws_secretsmanager_secret.oidc.id
}

# ---------- HTTPS certificate ----------
# No domain for the demo, so a self-signed certificate is generated and
# imported into ACM. Browsers will warn; click through. With a real domain:
# an ACM-issued certificate with DNS validation, which renews itself.
resource "tls_private_key" "alb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem       = tls_private_key.alb.private_key_pem
  validity_period_hours = 720
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  dns_names             = [aws_lb.main.dns_name]

  subject {
    common_name  = "${var.project}.demo.internal"
    organization = "Demo"
  }
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem

  lifecycle {
    create_before_destroy = true
  }
}
