#!/bin/bash

set -e

echo "[INFO] Nettoyage de l'environnement P2..."

# Activation du réseau de management libvirt si nécessaire.
if virsh net-info vagrant-libvirt >/dev/null 2>&1; then
    if ! virsh net-info vagrant-libvirt | grep -q "Active:.*yes"; then
        echo "[INFO] Activation du réseau vagrant-libvirt..."
        virsh net-start vagrant-libvirt >/dev/null
    fi
fi

# Destruction de la machine virtuelle gérée par Vagrant.
if ! vagrant status 2>/dev/null | grep -q "not created"; then
    echo "[INFO] Destruction de la machine virtuelle..."
    vagrant destroy -f
else
    echo "[INFO] Aucune machine virtuelle Vagrant à détruire."
fi

echo
echo "[INFO] Nettoyage des volumes orphelins du pool 'default'..."

for vol in $(virsh -c qemu:///system vol-list --pool default 2>/dev/null | awk 'NR>2 {print $1}'); do
    if [[ "$vol" == p2_* ]]; then
        echo "[INFO] Suppression du volume orphelin: $vol"
        virsh -c qemu:///system vol-delete --pool default "$vol" 2>/dev/null || true
    fi
done

echo
echo "[INFO] Vérification de l'état Vagrant..."

if vagrant status 2>/dev/null | grep -q "not created"; then
    echo "[OK] La machine virtuelle Vagrant n'existe plus."
else
    echo "[ERROR] La machine virtuelle est toujours présente."
    vagrant status
    exit 1
fi

echo
echo "[INFO] Domaines libvirt restants :"
virsh list --all

echo
echo "[INFO] Réseaux libvirt :"
virsh net-list --all

echo
echo "[INFO] Volumes restants dans le pool 'default' :"
virsh -c qemu:///system vol-list --pool default 2>/dev/null || true

echo
echo "[SUCCESS] Nettoyage terminé."
echo "[INFO] L'environnement est prêt pour un nouveau 'vagrant up'."
