# ---------- container registry ----------
resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE" # a tested tag can never be overwritten
  force_delete         = true        # demo only: lets destroy remove pushed images

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------- server image: official Rocky Linux 9 ----------
data "aws_ami" "rocky" {
  most_recent = true
  owners      = ["792107900819"] # Rocky Enterprise Software Foundation

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9.*.x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------- server identity: least privilege ----------
resource "aws_iam_role" "app" {
  name = "${var.project}-app"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Session Manager instead of SSH: no open port 22, no keys, every session logged.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull this one repository only. Cannot push, cannot read other repositories.
resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull-this-repo"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = aws_ecr_repository.app.arn
      }
    ]
  })
}

# CloudWatch agent: ships the audit log off the server and reports memory
# and disk. (Managed policy for reliability; production would scope it to
# the two log groups.)
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app"
  role = aws_iam_role.app.name
}

# ---------- launch template ----------
locals {
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image    = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

resource "aws_launch_template" "app" {
  name_prefix            = "${var.project}-"
  image_id               = data.aws_ami.rocky.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 only, and hop limit 1 so containers cannot reach the
  # instance's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.rocky.root_device_name
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region          = var.region
    registry        = local.registry
    image           = local.image
    image_tag       = var.image_tag
    alb_arn         = aws_lb.main.arn
    audit_log_group = aws_cloudwatch_log_group.app.name
    boot_log_group  = aws_cloudwatch_log_group.bootstrap.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-app", Project = var.project, Environment = "demo", DataClass = "synthetic" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.project}-app", Project = var.project, Environment = "demo", DataClass = "synthetic" }
  }

  # Pin the AMI found at first apply. Without this, a new Rocky release
  # would trigger an instance refresh (and a short outage) on any later apply.
  lifecycle {
    ignore_changes = [image_id]
  }
}

# ---------- auto scaling group: self-healing now, scaling later ----------
resource "aws_autoscaling_group" "app" {
  name                      = "${var.project}-app"
  vpc_zone_identifier       = aws_subnet.app[*].id
  min_size                  = 1
  max_size                  = 1 # phase 2: min 2, max 4, spread over both AZs
  desired_capacity          = 1
  health_check_type         = "ELB" # replace the server if the app fails its health check
  health_check_grace_period = 600   # time to install packages and pull the image
  target_group_arns         = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # A new image tag or template change rolls out a fresh server.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  # Do not boot the server until it has a route to the internet for packages.
  depends_on = [aws_route_table_association.app, aws_nat_gateway.main, aws_vpc_endpoint.s3]
}
