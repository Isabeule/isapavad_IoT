#!/bin/bash

# Arrête le script en cas d'erreur, de variable non définie
# ou d'échec d'une commande dans un pipeline.
set -euo pipefail

# Chemin du token K3s partagé avec le Server.
TOKEN_FILE="/vagrant/node-token"


# ------------------------------------------------------------
# TOKEN K3S
# ------------------------------------------------------------

echo "[INFO] Waiting for K3S token..."

# Temps maximal d'attente du token en secondes.
TIMEOUT=120

# Attend que le fichier contenant le token existe et ne soit pas vide.
while [ ! -s "$TOKEN_FILE" ]; do
  sleep 2
  TIMEOUT=$((TIMEOUT - 2))


  # Arrête le provisioning si le token n'est pas disponible
  # après expiration du délai.
  if [ "$TIMEOUT" -le 0 ]; then
    echo "ERROR: Le token K3s n'est pas dans /vagrant/node-token"
    exit 1
  fi
done

# Lit le token en supprimant les caractères de fin de ligne.
TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
echo "[OK] Token OK."


# ------------------------------------------------------------
# VÉRIFICATION DE LA CONNECTIVITÉ INITIALE
# ------------------------------------------------------------

echo
echo "[INFO] Configuration réseau initiale :"
ip route

if ! ip route show default | grep -q '^default'; then
  echo "[ERROR] Aucune route par défaut disponible avant l'installation."
  exit 1
fi

echo
echo "[INFO] Route par défaut utilisée pendant l'installation :"
ip route show default


# ------------------------------------------------------------
# INSTALLATION DE K3S AGENT
# ------------------------------------------------------------

echo
echo "[INFO] Route par défaut utilisée pendant l'installation :"
ip route | grep '^default'

# Met à jour la liste des paquets.
apt-get update

# Installe curl, nécessaire pour télécharger K3s.
apt-get install -y curl

# Télécharge et installe K3s en mode Agent.
# Le Worker rejoint le Server situé à 192.168.56.110:6443
# grâce au token K3s précédemment récupéré.
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION="v1.29.7+k3s1" \
K3S_URL="https://192.168.56.110:6443" \
K3S_TOKEN="$TOKEN" \
INSTALL_K3S_EXEC="agent --node-ip=192.168.56.111 --flannel-iface=eth1" \
sh -


# ------------------------------------------------------------
# CONFIGURATION RÉSEAU
# ------------------------------------------------------------

# Utilise le réseau privé P1 comme route par défaut.
# 192.168.56.1 est la passerelle libvirt du réseau p10.
ip route replace default via 192.168.56.1 dev eth1

# Supprime les éventuelles routes par défaut.
while read -r route; do
  if [[ "$route" != *"dev eth1"* ]]; then
    ip route del $route
  fi
done < <(ip route show default)


# ------------------------------------------------------------
# VÉRIFICATIONS
# ------------------------------------------------------------

# Affiche la route par défaut finale.
echo
echo "[INFO] Route par défaut finale du Worker :"
ip route show default

# Affiche l'adresse IPv4 de eth1.
echo
echo "[INFO] Interface réseau principale du Worker :"
ip -4 addr show eth1

# Vérifie que le service K3s Agent fonctionne.
echo
echo "[INFO] État du service K3s Agent :"
systemctl is-active k3s-agent

echo
echo "[OK] Configuration du Worker terminée."
