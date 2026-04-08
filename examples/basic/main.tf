provider "aws" {
  region = "us-east-1"
}

module "sftp" {
  source = "../../"

  aws_region         = "us-east-1"
  env                = "dev"
  vpc_id             = var.vpc_id
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids
  sftp_users         = var.sftp_users
}

output "sftp_endpoint" {
  value = module.sftp.sftp_endpoint
}

output "sftp_bucket_name" {
  value = module.sftp.sftp_bucket_name
}
