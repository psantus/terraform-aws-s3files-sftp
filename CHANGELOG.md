# Changelog

## 0.1.0 (2026-04-08)

Initial release.

- SFTP server on ECS Fargate using [atmoz/sftp](https://github.com/atmoz/sftp)
- S3 Files (NFS) volume for `/home` — files sync to S3 automatically
- EFS volume for `/etc/ssh/` — persistent SSH host keys across task restarts
- NLB on port 22
- S3 Files resources managed via AWS CLI (`terraform_data`) pending Terraform provider support ([PR #47325](https://github.com/hashicorp/terraform-provider-aws/pull/47325))
- Optional Route53 DNS record
