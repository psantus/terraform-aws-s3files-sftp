output "sftp_endpoint" {
  value = aws_lb.sftp.dns_name
}

output "sftp_bucket_name" {
  value = aws_s3_bucket.sftp.id
}

output "sftp_bucket_arn" {
  value = aws_s3_bucket.sftp.arn
}

output "s3files_file_system_id" {
  value = local.s3files_fs_id
}

output "s3files_file_system_arn" {
  value = local.s3files_fs_arn
}
