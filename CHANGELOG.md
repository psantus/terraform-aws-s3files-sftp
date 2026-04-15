# Changelog

## 0.6.0 (2026-04-16)

- Optional CloudWatch alarms for unhealthy NLB targets and ECS task failures (set `alarm_sns_topic_arn` to enable)

## 0.5.0 (2026-04-16)

- Auto scaling policies (CPU and memory target tracking) with `min_capacity` / `max_capacity` variables
- `desired_count` ignored in lifecycle to let the autoscaler manage it

## 0.4.0 (2026-04-15)

- **Fully native Terraform** — no more AWS CLI dependency
- Native `aws_ecs_task_definition` with `s3files_volume_configuration` (requires AWS provider >= 6.41)
- Removed `terraform_data` provisioners, `local` provider, and temp file artifacts

## 0.3.0 (2026-04-09)

- Add `allowed_cidr_blocks` variable to restrict NLB ingress (defaults to `0.0.0.0/0`)

## 0.2.0 (2026-04-09)

- **Breaking:** Module no longer creates the S3 bucket — pass `s3_bucket_arn` instead (bucket must have versioning enabled)
- Native `aws_s3files_file_system` and `aws_s3files_mount_target` resources (requires AWS provider >= 6.40)
- Removed `local` provider dependency and temp file artifacts
- NLB target group source IP stickiness for horizontal scaling
- EFS mounted at `/etc/ssh/host-keys/` with entrypoint wrapper for key persistence
- Removed `jq` as a prerequisite

## 0.1.0 (2026-04-08)

Initial release.

- SFTP server on ECS Fargate using [atmoz/sftp](https://github.com/atmoz/sftp)
- S3 Files (NFS) volume for `/home` — files sync to S3 automatically
- EFS volume for `/etc/ssh/` — persistent SSH host keys across task restarts
- NLB on port 22
- S3 Files resources managed via AWS CLI (`terraform_data`) pending Terraform provider support ([PR #47325](https://github.com/hashicorp/terraform-provider-aws/pull/47325))
- Optional Route53 DNS record
