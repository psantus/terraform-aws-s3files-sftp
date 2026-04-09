variable "aws_region" {
  type = string
}

variable "env" {
  type = string
}

variable "project_name" {
  type    = string
  default = "s3files-sftp"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket (must have versioning enabled)"
  type        = string
}

variable "sftp_users" {
  description = "atmoz/sftp user spec: user:password:uid:gid:dir (see https://github.com/atmoz/sftp)"
  type        = string
  sensitive   = true
  default     = "demo:demo:1000:1000:upload"
}

variable "logs_retention_in_days" {
  type    = number
  default = 7
}

variable "route53_zone_id" {
  type    = string
  default = ""
}

variable "sftp_dns_name" {
  type    = string
  default = ""
}
