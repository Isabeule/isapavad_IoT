#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="iot-cluster"
readonly KUBECTL_CONTEXT="k3d-${CLUSTER_NAME}"
readonly HOST_PORT="8888"
readonly LOADBALANCER_PORT="80"

info() {
    printf '[INFO] %s\n' "$*"
}

success() {
    printf '[SUCCESS] %s\n' "$*"
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cluster_exists() {
    k3d cluster list --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | grep -Fxq "${CLUSTER_NAME}"
}

wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout_seconds="$3"
    local elapsed=0

    info "Attente de la création du Deployment '${deployment}'..."

    until kubectl get deployment "${deployment}" \
        --namespace "${namespace}" \
        >/dev/null 2>&1; do

        if (( elapsed >= timeout_seconds )); then
            error "Le Deployment '${deployment}' n'a pas été créé dans le délai imparti."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# ---------------------------------------------------------------------------
# Vérification des dépendances
# ---------------------------------------------------------------------------

command_exists docker \
    || error "Docker n'est pas installé. Exécuter : sudo ./scripts/install.sh"

command_exists k3d \
    || error "K3d n'est pas installé. Exécuter : sudo ./scripts/install.sh"

command_exists kubectl \
    || error "kubectl n'est pas installé. Exécuter : sudo ./scripts/install.sh"

docker info >/dev/null 2>&1 \
    || error "Docker n'est pas accessible.
Exécuter ce script avec le groupe docker actif."

# ---------------------------------------------------------------------------
# Création du cluster
# ---------------------------------------------------------------------------

if cluster_exists; then
    info "Le cluster '${CLUSTER_NAME}' existe déjà."
else
    if ss -lnt 2>/dev/null \
        | awk '{print $4}' \
        | grep -Eq "(^|:|\])${HOST_PORT}$"; then

        error "Le port ${HOST_PORT} est déjà utilisé."
    fi

    info "Création du cluster K3d '${CLUSTER_NAME}'..."

    k3d cluster create "${CLUSTER_NAME}" \
        --servers 1 \
        --agents 0 \
        --port "${HOST_PORT}:${LOADBALANCER_PORT}@loadbalancer" \
        --wait

    success "Le cluster '${CLUSTER_NAME}' a été créé."
fi

# ---------------------------------------------------------------------------
# Configuration de kubectl
# ---------------------------------------------------------------------------

info "Sélection du contexte kubectl '${KUBECTL_CONTEXT}'..."

kubectl config use-context "${KUBECTL_CONTEXT}" >/dev/null

kubectl cluster-info >/dev/null 2>&1 \
    || error "Le cluster Kubernetes n'est pas accessible."

# ---------------------------------------------------------------------------
# Attente du nœud
# ---------------------------------------------------------------------------

info "Attente du nœud Kubernetes..."

kubectl wait \
    --for=condition=Ready \
    node \
    --all \
    --timeout=180s

# ---------------------------------------------------------------------------
# Attente de Traefik
# ---------------------------------------------------------------------------

wait_for_deployment \
    "kube-system" \
    "traefik" \
    300

info "Attente du démarrage de Traefik..."

kubectl rollout status \
    deployment/traefik \
    --namespace kube-system \
    --timeout=300s

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------

echo

success "Le cluster '${CLUSTER_NAME}' est opérationnel."

echo
echo "Cluster :"
echo

k3d cluster list

echo
echo "Nœuds :"
echo

kubectl get nodes

echo
echo "Pods système :"
echo

kubectl get pods \
    --namespace kube-system
