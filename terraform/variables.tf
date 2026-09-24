variable "project_id" {
  type    = string
  default = "codecrypto-ai"
}

variable "region" {
  type    = string
  default = "us-central1" # Iowa
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name" {
  type    = string
  default = "wp-spot"
}

# 4 vCPU / 8 GB
variable "machine_type" {
  type    = string
  default = "e2-custom-4-8192"
}

variable "data_disk_size_gb" {
  type    = number
  default = 40
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_source_ranges" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
