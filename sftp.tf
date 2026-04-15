###############################################################################
# S3 Files SFTP — atmoz/sftp on Fargate backed by S3 via S3 Files
#
# The ECS task definition is registered via AWS CLI because the provider's
# aws_ecs_task_definition does not yet support s3filesVolumeConfiguration.
# All other resources use native Terraform.
###############################################################################

# ─── IAM role assumed by S3 Files to sync bucket ↔ file-system ──────────────

resource "aws_iam_role" "s3files" {
  name = "${var.project_name}-s3files-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3FilesAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "elasticfilesystem.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:s3files:${var.aws_region}:${data.aws_caller_identity.current.account_id}:file-system/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "s3files" {
  name = "${var.project_name}-s3files-policy"
  role = aws_iam_role.s3files.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketPermissions"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketVersions"]
        Resource = var.s3_bucket_arn
        Condition = { StringEquals = { "aws:ResourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid      = "S3ObjectPermissions"
        Effect   = "Allow"
        Action   = ["s3:AbortMultipartUpload", "s3:DeleteObject*", "s3:GetObject*", "s3:List*", "s3:PutObject*"]
        Resource = "${var.s3_bucket_arn}/*"
        Condition = { StringEquals = { "aws:ResourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid      = "EventBridgeManage"
        Effect   = "Allow"
        Action   = ["events:DeleteRule", "events:DisableRule", "events:EnableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets"]
        Resource = ["arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"]
        Condition = { StringEquals = { "events:ManagedBy" = "elasticfilesystem.amazonaws.com" } }
      },
      {
        Sid      = "EventBridgeRead"
        Effect   = "Allow"
        Action   = ["events:DescribeRule", "events:ListRuleNamesByTarget", "events:ListRules", "events:ListTargetsByRule"]
        Resource = ["arn:aws:events:*:*:rule/*"]
      }
    ]
  })
}

# ─── Security groups ────────────────────────────────────────────────────────

resource "aws_security_group" "sftp_lb" {
  name        = "${var.project_name}-sftp-lb"
  description = "NLB for SFTP"
  vpc_id      = var.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sftp_app" {
  name        = "${var.project_name}-sftp-app"
  description = "ECS SFTP tasks"
  vpc_id      = var.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 22
    to_port         = 22
    security_groups = [aws_security_group.sftp_lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "nfs" {
  name        = "${var.project_name}-nfs"
  description = "Allow NFS from ECS tasks to S3 Files / EFS mount targets"
  vpc_id      = var.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 2049
    to_port         = 2049
    security_groups = [aws_security_group.sftp_app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── EFS for persistent SSH host keys (consistent fingerprint across tasks) ─

resource "aws_efs_file_system" "ssh_host_keys" {
  encrypted = true
  tags      = { Name = "${var.project_name}-ssh-host-keys" }
}

resource "aws_efs_mount_target" "ssh_host_keys" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.ssh_host_keys.id
  subnet_id       = each.value
  security_groups = [aws_security_group.nfs.id]
}

# ─── S3 Files file system (native Terraform, provider >= 6.40) ──────────────

resource "aws_s3files_file_system" "sftp" {
  bucket   = var.s3_bucket_arn
  role_arn = aws_iam_role.s3files.arn
  tags     = { Name = "${var.project_name}-${var.env}-sftp" }
}

resource "aws_s3files_mount_target" "sftp" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_s3files_file_system.sftp.id
  subnet_id       = each.value
  security_groups = [aws_security_group.nfs.id]
}

# ─── IAM: ECS task roles ────────────────────────────────────────────────────

resource "aws_iam_role" "task_execution_role" {
  name = "${var.project_name}-sftp-task-exec-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "task_exec_ecs" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_exec_ssm" {
  name = "${var.project_name}-sftp-task-exec-ssm"
  role = aws_iam_role.task_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "secretsmanager:GetSecretValue"]
      Resource = ["*"]
    }]
  })
}

resource "aws_iam_role" "task_role" {
  name = "${var.project_name}-sftp-task-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "task_role_s3files" {
  name = "${var.project_name}-sftp-task-s3files"
  role = aws_iam_role.task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3FilesClientAccess"
        Effect   = "Allow"
        Action   = ["s3files:ClientMount", "s3files:ClientWrite"]
        Resource = "*"
      },
      {
        Sid      = "S3ObjectReadAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${var.s3_bucket_arn}/*"
      },
      {
        Sid      = "S3BucketListAccess"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = var.s3_bucket_arn
      },
      {
        Sid      = "ECSExec"
        Effect   = "Allow"
        Action   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource = ["*"]
      }
    ]
  })
}

# ─── SSM parameter for SFTP users ───────────────────────────────────────────

resource "aws_ssm_parameter" "sftp_users" {
  name  = "/${var.project_name}/${var.env}/SFTP_USERS"
  type  = "SecureString"
  value = var.sftp_users
}

# ─── ECS Cluster ────────────────────────────────────────────────────────────

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "6.0.1"

  cluster_name = "${var.project_name}-sftp"

  default_capacity_provider_strategy = {
    FARGATE = { base = 1, weight = 100 }
  }

  cloudwatch_log_group_name              = "/${var.project_name}-sftp-ecs-exec-logs"
  cloudwatch_log_group_retention_in_days = var.logs_retention_in_days
}

# ─── NLB ────────────────────────────────────────────────────────────────────

resource "aws_lb" "sftp" {
  name               = "${var.project_name}-sftp"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.sftp_lb.id]
}

resource "aws_lb_target_group" "sftp" {
  name        = "${var.project_name}-sftp"
  port        = 22
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  stickiness {
    enabled = true
    type    = "source_ip"
  }
}

resource "aws_lb_listener" "sftp" {
  load_balancer_arn = aws_lb.sftp.arn
  port              = 22
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sftp.arn
  }
}

# ─── ECS task definition (AWS CLI — provider lacks s3filesVolumeConfiguration)

locals {
  task_family = "${var.project_name}-${var.env}-sftp"
}

resource "aws_cloudwatch_log_group" "sftp" {
  name              = "/aws/ecs/${local.task_family}/sftp"
  retention_in_days = var.logs_retention_in_days
}

resource "aws_ecs_task_definition" "sftp" {
  family                   = local.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "sftp-home"
    s3files_volume_configuration {
      file_system_arn = aws_s3files_file_system.sftp.arn
      root_directory  = "/"
    }
  }

  volume {
    name = "ssh-host-keys"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.ssh_host_keys.id
      transit_encryption = "ENABLED"
    }
  }

  container_definitions = jsonencode([
    {
      name              = "sftp"
      image             = "atmoz/sftp"
      cpu               = 256
      memoryReservation = 512
      essential         = true
      user              = "0"
      readonlyRootFilesystem = false

      entryPoint = ["sh", "-c"]
      command    = ["cp -n /etc/ssh/host-keys/ssh_host_*_key* /etc/ssh/ 2>/dev/null; /entrypoint sh -c 'cp -f /etc/ssh/ssh_host_*_key* /etc/ssh/host-keys/ 2>/dev/null; exec /usr/sbin/sshd -D -e'"]

      portMappings = [{ name = "sftp", containerPort = 22, hostPort = 22, protocol = "tcp" }]

      mountPoints = [
        { sourceVolume = "sftp-home", containerPath = "/home", readOnly = false },
        { sourceVolume = "ssh-host-keys", containerPath = "/etc/ssh/host-keys", readOnly = false },
      ]

      secrets = [{ name = "SFTP_USERS", valueFrom = aws_ssm_parameter.sftp_users.arn }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.sftp.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }

      restartPolicy = { enabled = true, ignoredExitCodes = [], restartAttemptPeriod = 60 }
      linuxParameters = { initProcessEnabled = true }
    }
  ])
}

# ─── ECS Service ────────────────────────────────────────────────────────────

resource "aws_ecs_service" "sftp" {
  name            = "${var.project_name}-${var.env}-sftp"
  cluster         = module.ecs.cluster_arn
  task_definition = aws_ecs_task_definition.sftp.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true
  force_new_deployment   = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.sftp_app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.sftp.arn
    container_name   = "sftp"
    container_port   = 22
  }
}

# ─── DNS (optional) ─────────────────────────────────────────────────────────

resource "aws_route53_record" "sftp" {
  count   = var.route53_zone_id != "" ? 1 : 0
  name    = var.sftp_dns_name
  type    = "CNAME"
  zone_id = var.route53_zone_id
  ttl     = 300
  records = [aws_lb.sftp.dns_name]
}
