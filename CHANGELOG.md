# Changelog

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
