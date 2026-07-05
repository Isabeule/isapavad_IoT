#!/bin/bash
set -e

echo "[INFO] Suppression des machines Vagrant..."
vagrant destroy -f || true

echo "[INFO] Suppression des domaines libvirt restants..."
for vm in $(virsh list --all --name | grep '^p1_'); do
    echo "Suppression de $vm"
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
done

echo
echo "[INFO] Suppression des fichiers locaux..."
rm -rf .vagrant
rm -f node-token

echo
echo "[VÉRIFICATION] Machines libvirt :"

if virsh list --all | grep -q "p1_"; then
    echo "Des machines du projet existent encore :"
    virsh list --all | grep p1_
else
    echo "Aucune machine libvirt du projet trouvée"
fi

echo
echo "[VÉRIFICATION] Fichiers locaux :"

if [ ! -d .vagrant ]; then
    echo "Répertoire .vagrant supprimé"
else
    echo "Répertoire .vagrant encore présent"
fi

if [ ! -f node-token ]; then
    echo "Fichier node-token supprimé"
else
    echo "Fichier node-token encore présent"
fi

echo
echo "[OK] Nettoyage du projet terminé"
