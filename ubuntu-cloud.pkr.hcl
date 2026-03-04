packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

// --- VM template build ---
source "proxmox-iso" "ubuntu-server" {
  # Proxmox
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_skip_tls_verify
  node                     = var.proxmox_node

  task_timeout = var.task_timeout

  # VM general
  vm_id                = 0
  vm_name              = "tpl-ubuntu-server"
  template_description = "Ubuntu Server (Capstone)"
  os                   = "l26"

  boot_iso {
    type = "scsi"

    iso_url          = "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
    iso_checksum     = "file:https://releases.ubuntu.com/22.04/SHA256SUMS"
    iso_storage_pool = var.iso_storage
    iso_download_pve = true
    unmount          = true
  }

  # Guest
  qemu_agent      = true
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = var.disk_size
    format       = "raw"
    storage_pool = var.vm_storage
    type         = "virtio"
  }

  cores              = var.cores
  memory             = var.memory
  ballooning_minimum = var.ballooning_minimum

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge_lan
    firewall = false
    vlan_tag = var.lan_vlan_tag
  }

  vga {
    type   = "std"
    memory = 64
  }

  # Cloud-init drive (so clones can use cloud-init if you want)
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage

  boot_key_interval = "50ms"
  boot_command = [
    "<esc><wait>",
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz ip=dhcp autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ cloud-config-url=/dev/null ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  boot      = "c"
  boot_wait = "5s"

  http_content = {
    "/user-data" = templatefile("${path.root}/http/user-data.tpl", {
      hostname             = var.hostname
      ssh_public_key       = var.ssh_public_key
      ubuntu_password_hash = var.ubuntu_password_hash
    })
    "/meta-data" = templatefile("${path.root}/http/meta-data.tpl", {
      hostname = var.hostname
    })
  }

  http_bind_address = "0.0.0.0"
  http_port_min     = 8902
  http_port_max     = 8902

  ssh_username = "ubuntu"
  ssh_password = "ubuntu"
  ssh_timeout  = "2h"

  # If you provide PACKER_SSH_PRIVATE_KEY_FILE, packer will prefer it.
  ssh_private_key_file = var.ssh_private_key_file != "" ? var.ssh_private_key_file : null
}
