###############################################################################
# S3 Files SFTP — atmoz/sftp on Fargate backed by S3 via S3 Files
#
# S3 Files resources (file-system, mount-target) are managed through
# terraform_data + AWS CLI because the Terraform provider does not yet
# support the s3files service (PR #47325 pending).
#
# The ECS task definition is also registered via CLI because the provider's
# aws_ecs_task_definition resource does not yet support
# s3filesVolumeConfiguration.
###############################################################################

locals {
  sftp_bucket_name = "${var.project_name}-${var.env}-sftp"
  fs_name          = "${var.project_name}-${var.env}-sftp"
}

# ─── S3 bucket for SFTP data ────────────────────────────────────────────────

resource "aws_s3_bucket" "sftp" {
  bucket = local.sftp_bucket_name
  tags   = { Name = local.sftp_bucket_name }
}

resource "aws_s3_bucket_versioning" "sftp" {
  bucket = aws_s3_bucket.sftp.id
  versioning_configuration { status = "Enabled" } # Required by S3 Files
}

resource "aws_s3_bucket_public_access_block" "sftp" {
  bucket                  = aws_s3_bucket.sftp.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

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
        Resource = aws_s3_bucket.sftp.arn
        Condition = { StringEquals = { "aws:ResourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid      = "S3ObjectPermissions"
        Effect   = "Allow"
        Action   = ["s3:AbortMultipartUpload", "s3:DeleteObject*", "s3:GetObject*", "s3:List*", "s3:PutObject*"]
        Resource = "${aws_s3_bucket.sftp.arn}/*"
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
    cidr_blocks = ["0.0.0.0/0"]
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

resource "aws_security_group" "s3files_mt" {
  name        = "${var.project_name}-s3files-mt"
  description = "Allow NFS from ECS tasks to S3 Files mount targets"
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
  security_groups = [aws_security_group.s3files_mt.id] # reuses NFS 2049 SG
}

# ─── S3 Files file system (AWS CLI) ─────────────────────────────────────────

resource "terraform_data" "s3files_file_system" {
  input = {
    bucket   = aws_s3_bucket.sftp.arn
    role_arn = aws_iam_role.s3files.arn
    region   = var.aws_region
    fs_name  = local.fs_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      FS_OUTPUT=$(aws s3files create-file-system \
        --bucket "${self.input.bucket}" \
        --role-arn "${self.input.role_arn}" \
        --tags key=Name,value=${self.input.fs_name} \
        --accept-bucket-warning \
        --region "${self.input.region}" \
        --output json)

      FS_ID=$(echo "$FS_OUTPUT" | jq -r '.fileSystemId')
      echo "$FS_ID" > /tmp/s3files_fs_id_${self.input.fs_name}

      for i in $(seq 1 60); do
        STATUS=$(aws s3files get-file-system --file-system-id "$FS_ID" \
          --region "${self.input.region}" --query 'status' --output text)
        [ "$STATUS" = "available" ] && break
        sleep 10
      done
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      FS_ID=$(cat /tmp/s3files_fs_id_${self.input.fs_name} 2>/dev/null || true)
      [ -z "$FS_ID" ] && exit 0

      # Delete mount targets first
      MTS=$(aws s3files list-mount-targets --file-system-id "$FS_ID" \
        --region "${self.input.region}" --query 'mountTargets[].mountTargetId' --output text 2>/dev/null || true)
      for MT in $MTS; do
        aws s3files delete-mount-target --mount-target-id "$MT" --region "${self.input.region}" || true
      done
      sleep 30

      aws s3files delete-file-system --file-system-id "$FS_ID" --region "${self.input.region}" || true
      rm -f /tmp/s3files_fs_id_${self.input.fs_name}
    EOT
  }
}

data "local_file" "s3files_fs_id" {
  filename   = "/tmp/s3files_fs_id_${local.fs_name}"
  depends_on = [terraform_data.s3files_file_system]
}

locals {
  s3files_fs_id  = trimspace(data.local_file.s3files_fs_id.content)
  s3files_fs_arn = "arn:aws:s3files:${var.aws_region}:${data.aws_caller_identity.current.account_id}:file-system/${local.s3files_fs_id}"
}

# ─── S3 Files mount targets (AWS CLI) ───────────────────────────────────────

resource "terraform_data" "s3files_mount_targets" {
  for_each = toset(var.private_subnet_ids)

  input = {
    fs_id     = local.s3files_fs_id
    subnet_id = each.value
    sg_id     = aws_security_group.s3files_mt.id
    region    = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      MT_OUTPUT=$(aws s3files create-mount-target \
        --file-system-id "${self.input.fs_id}" \
        --subnet-id "${self.input.subnet_id}" \
        --security-groups "${self.input.sg_id}" \
        --region "${self.input.region}" \
        --output json)

      MT_ID=$(echo "$MT_OUTPUT" | jq -r '.mountTargetId')
      echo "$MT_ID" > /tmp/s3files_mt_${self.input.subnet_id}

      for i in $(seq 1 60); do
        STATUS=$(aws s3files get-mount-target --mount-target-id "$MT_ID" \
          --region "${self.input.region}" --query 'status' --output text)
        [ "$STATUS" = "available" ] && break
        sleep 10
      done
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      MT_ID=$(cat /tmp/s3files_mt_${self.input.subnet_id} 2>/dev/null || true)
      [ -z "$MT_ID" ] && exit 0
      aws s3files delete-mount-target --mount-target-id "$MT_ID" --region "${self.input.region}" || true
      rm -f /tmp/s3files_mt_${self.input.subnet_id}
    EOT
  }

  depends_on = [terraform_data.s3files_file_system]
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
        Resource = "${aws_s3_bucket.sftp.arn}/*"
      },
      {
        Sid      = "S3BucketListAccess"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.sftp.arn
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

resource "aws_cloudwatch_log_group" "sftp" {
  name              = "/aws/ecs/${var.project_name}-${var.env}-sftp/sftp"
  retention_in_days = var.logs_retention_in_days
}

resource "terraform_data" "ecs_task_definition" {
  input = {
    family    = "${var.project_name}-${var.env}-sftp"
    region    = var.aws_region
    fs_arn    = local.s3files_fs_arn
    efs_id    = aws_efs_file_system.ssh_host_keys.id
    exec_role = aws_iam_role.task_execution_role.arn
    task_role = aws_iam_role.task_role.arn
    log_group = aws_cloudwatch_log_group.sftp.name
    ssm_arn   = aws_ssm_parameter.sftp_users.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      cat > /tmp/taskdef_${self.input.family}.json <<'TASKDEF'
      {
        "family": "${self.input.family}",
        "networkMode": "awsvpc",
        "requiresCompatibilities": ["FARGATE"],
        "cpu": "256",
        "memory": "512",
        "executionRoleArn": "${self.input.exec_role}",
        "taskRoleArn": "${self.input.task_role}",
        "runtimePlatform": {
          "cpuArchitecture": "X86_64",
          "operatingSystemFamily": "LINUX"
        },
        "volumes": [
          {
            "name": "sftp-home",
            "configuredAtLaunch": false,
            "s3filesVolumeConfiguration": {
              "fileSystemArn": "${self.input.fs_arn}",
              "rootDirectory": "/"
            }
          },
          {
            "name": "ssh-host-keys",
            "efsVolumeConfiguration": {
              "fileSystemId": "${self.input.efs_id}",
              "transitEncryption": "ENABLED"
            }
          }
        ],
        "containerDefinitions": [
          {
            "name": "sftp",
            "image": "atmoz/sftp",
            "cpu": 256,
            "memoryReservation": 512,
            "essential": true,
            "user": "0",
            "readonlyRootFilesystem": false,
            "portMappings": [
              { "name": "sftp", "containerPort": 22, "hostPort": 22, "protocol": "tcp" }
            ],
            "mountPoints": [
              { "sourceVolume": "sftp-home", "containerPath": "/home", "readOnly": false },
              { "sourceVolume": "ssh-host-keys", "containerPath": "/etc/ssh/", "readOnly": false }
            ],
            "secrets": [
              { "name": "SFTP_USERS", "valueFrom": "${self.input.ssm_arn}" }
            ],
            "logConfiguration": {
              "logDriver": "awslogs",
              "options": {
                "awslogs-group": "${self.input.log_group}",
                "awslogs-region": "${self.input.region}",
                "awslogs-stream-prefix": "ecs"
              }
            },
            "restartPolicy": {
              "enabled": true,
              "ignoredExitCodes": [],
              "restartAttemptPeriod": 60
            },
            "linuxParameters": { "initProcessEnabled": true }
          }
        ]
      }
TASKDEF

      TASK_OUTPUT=$(aws ecs register-task-definition \
        --cli-input-json file:///tmp/taskdef_${self.input.family}.json \
        --region "${self.input.region}" \
        --output json)

      TASK_ARN=$(echo "$TASK_OUTPUT" | jq -r '.taskDefinition.taskDefinitionArn')
      echo "$TASK_ARN" > /tmp/taskdef_arn_${self.input.family}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      TASK_ARN=$(cat /tmp/taskdef_arn_${self.input.family} 2>/dev/null || true)
      [ -z "$TASK_ARN" ] && exit 0
      aws ecs deregister-task-definition --task-definition "$TASK_ARN" \
        --region "${self.input.region}" || true
      rm -f /tmp/taskdef_arn_${self.input.family} /tmp/taskdef_${self.input.family}.json
    EOT
  }

  depends_on = [
    terraform_data.s3files_mount_targets,
    aws_efs_mount_target.ssh_host_keys,
    aws_cloudwatch_log_group.sftp,
  ]
}

data "local_file" "taskdef_arn" {
  filename   = "/tmp/taskdef_arn_${var.project_name}-${var.env}-sftp"
  depends_on = [terraform_data.ecs_task_definition]
}

# ─── ECS Service ────────────────────────────────────────────────────────────

resource "aws_ecs_service" "sftp" {
  name            = "${var.project_name}-${var.env}-sftp"
  cluster         = module.ecs.cluster_arn
  task_definition = trimspace(data.local_file.taskdef_arn.content)
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

  depends_on = [terraform_data.ecs_task_definition]

  lifecycle {
    ignore_changes = [task_definition]
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
