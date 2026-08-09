#!/bin/bash
set -e

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION="v1.29.7+k3s1" \
INSTALL_K3S_EXEC="server --node-ip=192.168.56.110 --flannel-iface=eth1" \
sh -

# attendre que l'API server soit rdy
until kubectl get nodes >/dev/null 2>&1; do sleep 2; done

kubectl apply -f "/confs"