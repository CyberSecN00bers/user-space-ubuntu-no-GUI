
build {
  name    = "ubuntu"
  sources = ["source.proxmox-iso.ubuntu-server"]


  # Proxmox cloud-init tweaks
  provisioner "file" {
    source      = "files/99-pve.cfg"
    destination = "/tmp/99-pve.cfg"
  }

  # User stack + provision script
  provisioner "shell" {
    inline = ["mkdir -p /tmp/capstone-userstack"]
  }

  provisioner "file" {
    source      = "files/userstack/"
    destination = "/tmp/capstone-userstack"
  }

  provisioner "shell" {
    inline = ["mkdir -p /tmp/scripts"]
  }

  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/scripts/"
  }

  provisioner "shell" {
    inline = [
      "sudo chmod +x /tmp/scripts/provision-ubuntu-userstack.sh",
      "cd /tmp/scripts && sudo -E bash ./provision-ubuntu-userstack.sh"
    ]
  }

  provisioner "shell" {
    inline = ["sudo cp /tmp/99-pve.cfg /etc/cloud/cloud.cfg.d/99-pve.cfg"]
  }
}
