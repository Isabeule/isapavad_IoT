#!/bin/bash

# Arrête le script si une commande non explicitement gérée échoue.
set -e


# ------------------------------------------------------------
# 1. SUPPRESSION DES MACHINES VAGRANT
# ------------------------------------------------------------

echo "[INFO] Suppression des machines Vagrant..."

# Demande à Vagrant de détruire les VMs sans confirmation.
# "|| true" permet de continuer si les VMs n'existent déjà plus.
vagrant destroy -f || true


# ------------------------------------------------------------
# 2. SUPPRESSION DES MACHINES LIBVIRT RESTANTES
# ------------------------------------------------------------

echo "[INFO] Suppression des domaines libvirt restants..."

# Recherche les domaines libvirt.
for vm in $(virsh list --all --name | grep '^p1_'); do

    # Affiche le nom de la VM en cours de suppression.
    echo "[INFO] Suppression de $vm..."

    # Arrête brutalement la VM si elle est encore démarrée.
    # Les erreurs sont ignorées si elle est déjà arrêtée.
    virsh destroy "$vm" 2>/dev/null || true

    # Supprime la définition libvirt de la VM et ses disques.
    virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
done


# ------------------------------------------------------------
# 3. SUPPRESSION DU RÉSEAU PRIVÉ P1
# ------------------------------------------------------------

echo "[INFO] Suppression du réseau libvirt p10..."

# Vérifie si le réseau p10 existe dans libvirt.
if virsh net-info p10 >/dev/null 2>&1; then

    # Arrête p10 seulement s'il est actuellement actif.
    if virsh net-info p10 | grep -q "Active:.*yes"; then
        virsh net-destroy p10
    fi

    # Supprime définitivement la définition du réseau p10.
    virsh net-undefine p10

    # Confirme sa suppression.
    echo "[OK] Réseau p10 supprimé."
else

    # Informe que le réseau était déjà absent.
    echo "[OK] Réseau p10 déjà absent."
fi


# ------------------------------------------------------------
# 4. SUPPRESSION DES FICHIERS LOCAUX
# ------------------------------------------------------------

echo "[INFO] Suppression des fichiers locaux..."

# Supprime l'état local enregistré par Vagrant.
rm -rf .vagrant

# Supprime l'ancien token utilisé par le worker pour rejoindre K3s.
rm -f node-token


# ------------------------------------------------------------
# 5. VÉRIFICATIONS
# ------------------------------------------------------------

echo

# Affiche l'étape de vérification des machines.
echo "[VÉRIFICATION] Machines libvirt :"

# Vérifie s'il existe encore un domaine libvirt ".
if virsh list --all --name | grep -q '^p1_'; then

    # Signale que des machines du projet existent encore.
    echo "[ERREUR] Des machines libvirt du projet existent encore :"

    # Affiche les machines restantes.
    virsh list --all --name | grep '^p1_'
else

    # Confirme qu'aucune VM P1 n'existe encore.
    echo "[OK] Aucune machine libvirt du projet trouvée."
fi


echo

# Affiche l'étape de vérification du réseau.
echo "[VÉRIFICATION] Réseau p10 :"

# Vérifie si le réseau p10 existe encore.
if virsh net-info p10 >/dev/null 2>&1; then

    # Signale que le réseau p10 existe toujours.
    echo "[ERREUR] Le réseau p10 existe encore."
else

    # Confirme sa suppression.
    echo "[OK] Réseau p10 supprimé."
fi


echo

# Affiche l'étape de vérification des fichiers locaux.
echo "[VÉRIFICATION] Fichiers locaux :"

# Vérifie que le dossier .vagrant a bien été supprimé.
if [ ! -d .vagrant ]; then

    # Confirme la suppression.
    echo "[OK] Répertoire .vagrant supprimé."
else

    # Signale que le dossier existe toujours.
    echo "[ERREUR] Répertoire .vagrant encore présent."
fi

# Vérifie que le fichier node-token a bien été supprimé.
if [ ! -f node-token ]; then

    # Confirme la suppression.
    echo "[OK] Fichier node-token supprimé."
else

    # Signale que le fichier existe toujours.
    echo "[ERREUR] Fichier node-token encore présent."
fi


echo

# Indique que toutes les étapes de nettoyage ont été exécutées.
echo "[OK] Nettoyage complet terminé."