# --- Pareja de claves SSH (generada por Terraform) ---
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/../keys/${var.name}"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.ssh.public_key_openssh
  filename        = "${path.module}/../keys/${var.name}.pub"
  file_permission = "0644"
}

# --- IP pública estática ---
resource "google_compute_address" "ip" {
  name   = "${var.name}-ip"
  region = var.region
}

# --- Disco de datos independiente (sobrevive a la VM) ---
resource "google_compute_disk" "data" {
  name = "${var.name}-data"
  type = "pd-balanced"
  zone = var.zone
  size = var.data_disk_size_gb
}

# --- Firewall ---
resource "google_compute_firewall" "web" {
  name          = "${var.name}-web"
  network       = "default"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.name}-ssh"
  network       = "default"
  source_ranges = var.ssh_source_ranges
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# --- VM Spot ---
resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [var.name]

  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    on_host_maintenance         = "TERMINATE"
    instance_termination_action = "STOP"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.ip.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${tls_private_key.ssh.public_key_openssh}"
  }

  # El disco de datos se gestiona con google_compute_attached_disk
  lifecycle {
    ignore_changes = [attached_disk]
  }
}

resource "google_compute_attached_disk" "data" {
  disk        = google_compute_disk.data.id
  instance    = google_compute_instance.vm.id
  device_name = "data"
}

# --- Inventario Ansible ---
locals {
  wp_domain = "wp-${replace(google_compute_address.ip.address, ".", "-")}.sslip.io"
}

resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = <<-EOT
    [wordpress]
    ${google_compute_address.ip.address} ansible_user=${var.ssh_user} ansible_ssh_private_key_file=${abspath(local_sensitive_file.private_key.filename)} wp_domain=${local.wp_domain}

    [wordpress:vars]
    ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'
  EOT
}
