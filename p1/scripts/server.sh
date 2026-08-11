#!/bin/bash

# Arrête le script en cas d'erreur, de variable non définie
# ou d'échec d'une commande dans un pipeline.
set -euo pipefail


# ------------------------------------------------------------
# VÉRIFICATION DE LA CONNECTIVITÉ INITIALE
# ------------------------------------------------------------

echo "[INFO] Configuration réseau initiale :"
ip route

# Vérifie qu'une route par défaut existe avant toute installation.
if ! ip route show default | grep -q '^default'; then
  echo "[ERROR] Aucune route par défaut disponible avant l'installation."
  exit 1
fi

echo
echo "[INFO] Route par défaut utilisée pendant l'installation :"
ip route show default



# ------------------------------------------------------------
# INSTALLATION DE K3S SERVER
# ------------------------------------------------------------

# Met à jour la liste des paquets.
apt-get update

# Installe curl, nécessaire pour télécharger K3s.
apt-get install -y curl

# Télécharge et installe K3s dans la version définie.
# Configure cette machine comme Server du cluster.
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



# ------------------------------------------------------------
# TOKEN K3S
# ------------------------------------------------------------

#Temps max d'attente de la création du token en secondes
TIMEOUT=120

# Attend que K3s crée un fichier token non vide.
while [ ! -s /var/lib/rancher/k3s/server/node-token ]; do
  sleep 2
  TIMEOUT=$((TIMEOUT - 2))

  # Arrête le script si le token n'est pas créé dans le délai prévu.
  if [ "$TIMEOUT" -le 0 ]; then
    echo "[ERREUR] Le token du serveur K3s n'a pas été créé."
    exit 1
  fi
done

# Copie le token dans /vagrant lorsqu'il est disponible.
if [ -d /vagrant ]; then
  cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
  
  # Supprime un éventuel caractère CR en fin de ligne.
  sed -i 's/\r$//' /vagrant/node-token
  
  # Autorise la lecture du token depuis le dossier partagé.
  chmod 644 /vagrant/node-token

  echo "[OK] Token copié dans /vagrant/node-token"
fi



# ------------------------------------------------------------
# CONFIGURATION DE L'INTERFACE PRINCIPALE
# ------------------------------------------------------------

# Le réseau P1 devient maintenant le réseau de la route par défaut.
ip route replace default via 192.168.56.1 dev eth1

# Supprime les éventuelles autres routes par défaut.
while read -r route; do
  if [[ "$route" != *"dev eth1"* ]]; then
    ip route del $route
  fi
done < <(ip route show default)

# ------------------------------------------------------------
# VÉRIFICATIONS
# ------------------------------------------------------------

# Affiche la route par défaut finale.
echo "[INFO] Route par défaut du Server :"
ip route show default

# Affiche l'adresse IPv4 de eth1.
echo
echo "[INFO] Interface réseau principale (eth1) du Server :"
ip -4 addr show eth1

# Vérifie que le service K3s Server fonctionne.
echo
echo "[INFO] État du service K3s Server :"
systemctl is-active k3s

echo
echo "[OK] Configuration du Server terminée."
