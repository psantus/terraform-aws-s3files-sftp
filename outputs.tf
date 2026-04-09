output "sftp_endpoint" {
  value = aws_lb.sftp.dns_name
}

output "s3files_file_system_id" {
  value = aws_s3files_file_system.sftp.id
}

output "s3files_file_system_arn" {
  value = aws_s3files_file_system.sftp.arn
}
