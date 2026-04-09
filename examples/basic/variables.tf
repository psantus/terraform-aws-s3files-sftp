variable "env" {
  type    = string
  default = "dev"
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

variable "sftp_users" {
  type      = string
  sensitive = true
  default   = "demo:demo:1000:1000:upload"
}
