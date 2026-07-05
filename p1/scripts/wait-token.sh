#!/bin/bash
set -e

TIMEOUT=300

while [ "$TIMEOUT" -gt 0 ]; do
  if vagrant ssh isapavadS -c "sudo test -s /var/lib/rancher/k3s/server/node-token" >/dev/null 2>&1; then
    vagrant ssh isapavadS -c "sudo cat /var/lib/rancher/k3s/server/node-token" | tr -d '\r\n' > node-token
    chmod 600 node-token
    echo "[OK] K3s token copied to host"
    exit 0
  fi

  echo "[INFO] Waiting for isapavadS token..."
  sleep 5
  TIMEOUT=$((TIMEOUT - 5))
done

echo "ERROR: K3s token not available from isapavadS"
exit 1
