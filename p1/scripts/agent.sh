#!/bin/bash
set -e

TOKEN_FILE="/vagrant/node-token"

echo "[INFO] Waiting for K3S token..."

TIMEOUT=120
while [ ! -s "$TOKEN_FILE" ]; do
  sleep 2
  TIMEOUT=$((TIMEOUT - 2))

  if [ "$TIMEOUT" -le 0 ]; then
    echo "ERROR: K3S token not found in /vagrant/node-token"
    exit 1
  fi
done

TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION="v1.29.7+k3s1" \
K3S_URL="https://192.168.56.110:6443" \
K3S_TOKEN="$TOKEN" \
INSTALL_K3S_EXEC="agent --node-ip=192.168.56.111 --flannel-iface=eth1" \
sh -
