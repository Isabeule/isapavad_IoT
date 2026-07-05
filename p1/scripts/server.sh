#!/bin/bash
set -e

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION="v1.29.7+k3s1" \
INSTALL_K3S_EXEC="server \
--node-ip=192.168.56.110 \
--flannel-iface=eth1 \
--write-kubeconfig-mode=644 \
--disable=traefik \
--disable=servicelb \
--disable=metrics-server" \
sh -

while [ ! -f /var/lib/rancher/k3s/server/node-token ]; do
  sleep 1
done

if [ -d /vagrant ]; then
  cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
  sed -i 's/\r$//' /vagrant/node-token
  chmod 644 /vagrant/node-token
fi
