#!/bin/bash
set -e

# Configuration réseau pour la P2 :
# - eth0 garde son DHCP pour Vagrant/SSH
# - eth0 n'installe pas de route par défaut
# - eth1 porte l'IP imposée 192.168.56.110
# - eth1 devient l'unique route par défaut

cat > /etc/netplan/99-iot-network.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false

    eth1:
      addresses:
        - 192.168.56.110/24
      routes:
        - to: default
          via: 192.168.56.1
EOF

chmod 600 /etc/netplan/99-iot-network.yaml

netplan generate
netplan apply
