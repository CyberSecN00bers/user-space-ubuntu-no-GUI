variable "proxmox_url" {
  type = string
  default = env("PROXMOX_URL")
}

variable "proxmox_username" {
  type = string
  default = env("PROXMOX_USERNAME")
}

variable "proxmox_token" {
  type      = string
  sensitive = true
  default = env("PROXMOX_TOKEN")
}

variable "proxmox_node" {
  type = string
  default = env("PROXMOX_NODE")
}

variable "proxmox_skip_tls_verify" {
  type    = bool
  default = true
}

variable "iso_storage" {
  type = string
  default = env("PACKER_ISO_STORAGE")
}

variable "vm_storage" {
  type = string
}

variable "proxmox_storage" {
  type = string
}

variable "bridge_lan" {
  type    = string
  default = env("PACKER_BRIDGE_LAN")
}

variable "lan_vlan_tag" {
  type    = number
  default = 10
}

variable "ssh_public_key" {
  type    = string
  default = env("PACKER_SSH_PUBLIC_KEY")
}

variable "ssh_private_key_file" {
  type    = string
  default = env("PACKER_SSH_PRIVATE_KEY")
}

variable "hostname" {
  type    = string
  default = "ubuntu-userstack"
}

variable "ubuntu_password_hash" {
  type = string
  default = "$6$rounds=656000$Q60Ql0NqJ/sk3r.Z$39aQ3iPEkDF5x.GbXAPEmZuKNxWwEd9jiGO5jdZ0lIumyt/saqtacJNpZyumFPq2xuBrA4OxVLCMCkuijcU6T0"
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 4096
}

variable "ballooning_minimum" {
  type    = number
  default = 0
}

variable "disk_size" {
  type    = string
  default = "30G"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "task_timeout" {
  type    = string
  default = "2h"
}
