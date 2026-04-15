resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "sftp" {
  bucket = "s3files-sftp-${var.env}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "sftp" {
  bucket = aws_s3_bucket.sftp.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "sftp" {
  bucket                  = aws_s3_bucket.sftp.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "sftp" {
  source = "../../"

  aws_region         = "us-east-1"
  env                = var.env
  vpc_id             = var.vpc_id
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids
  s3_bucket_arn      = aws_s3_bucket.sftp.arn
  sftp_users         = var.sftp_users
}

output "sftp_endpoint" {
  value = module.sftp.sftp_endpoint
}

# Optional: upload an SSH public key for key-based auth
# Users with empty password in sftp_users (e.g. "keyuser::1002:1000:upload")
# can only authenticate via SSH key.
#
# resource "aws_s3_object" "user_ssh_key" {
#   bucket  = aws_s3_bucket.sftp.id
#   key     = "keyuser/.ssh/keys/id_rsa.pub"
#   content = file("~/.ssh/id_rsa.pub")
# }

output "sftp_bucket_name" {
  value = aws_s3_bucket.sftp.id
}
