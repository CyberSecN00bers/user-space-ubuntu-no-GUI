proxmox_skip_tls_verify = true
proxmox_username="root@pam!packer"

vm_storage      = "hdd-lvm"
proxmox_storage = "local-lvm"
iso_storage     = "hdd-data"

template_vm_id       = 0
template_name        = "tpl-ubuntu-server"
template_description = "Ubuntu Server (Capstone)"
hostname             = "ubuntu-userstack"

cores              = 4
memory             = 6144
ballooning_minimum = 0
disk_size          = "50G"

# Ubuntu Server ISO (amd64) + checksum
iso_url      = "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
iso_checksum = "file:https://releases.ubuntu.com/22.04/SHA256SUMS"

lan_vlan_tag = 10
task_timeout = "2h"
