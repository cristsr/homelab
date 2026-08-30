version: 2
ethernets:
  eth0:
    match:
      macaddress: "${mac_address}"
    set-name: eth0
    dhcp4: false
    addresses: ["${ip_cidr}"]
    gateway4: ${gateway}
    nameservers:
      addresses: [${dns_servers}]
