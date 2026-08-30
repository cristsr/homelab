#cloud-config
hostname: ${hostname}
fqdn: ${hostname}.local
manage_etc_hosts: true
timezone: ${timezone}

users:
  - name: ${ssh_user}
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

ssh_pwauth: false

growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true

package_update: true
package_upgrade: false
packages:
  - curl
  - vim
  - bash-completion
  - python3

runcmd:
  - echo 'cloud-init base listo, configuracion de k0s la hace Ansible por SSH'
