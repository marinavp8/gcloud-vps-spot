output "ip" {
  value = google_compute_address.ip.address
}

output "wp_url" {
  value = "http://${local.wp_domain}"
}

output "ssh" {
  value = "ssh -i keys/${var.name} ${var.ssh_user}@${google_compute_address.ip.address}"
}
