#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="iot-cluster"

info() {
    printf '[INFO] %s\n' "$*"
}

success() {
    printf '[SUCCESS] %s\n' "$*"
}

if ! command -v k3d >/dev/null 2>&1; then
    info "K3d n'est pas installé : aucun cluster à supprimer."
    exit 0
fi

if k3d cluster list --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "${CLUSTER_NAME}"; then

    info "Suppression du cluster '${CLUSTER_NAME}'..."

    k3d cluster delete "${CLUSTER_NAME}"

    success "Le cluster a été supprimé."
else
    info "Aucun cluster '${CLUSTER_NAME}' n'existe."
fi
