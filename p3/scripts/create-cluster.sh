#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="iot-cluster"
readonly HOST_PORT="8888"
readonly CLUSTER_HTTP_PORT="80"
readonly KUBECTL_CONTEXT="k3d-${CLUSTER_NAME}"

info() {
    echo "[INFO] $*"
}

success() {
    echo "[SUCCESS] $*"
}

warning() {
    echo "[WARNING] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

on_error() {
    local exit_code=$?
    local line_number=$1

    echo "[ERROR] Échec du script à la ligne ${line_number}." >&2
    exit "${exit_code}"
}

trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Vérification des dépendances
# ---------------------------------------------------------------------------

info "Vérification des dépendances..."

command_exists docker \
    || error "Docker n'est pas installé. Exécuter d'abord : sudo ./scripts/install.sh"

command_exists k3d \
    || error "K3d n'est pas installé. Exécuter d'abord : sudo ./scripts/install.sh"

command_exists kubectl \
    || error "kubectl n'est pas installé. Exécuter d'abord : sudo ./scripts/install.sh"

# ---------------------------------------------------------------------------
# Vérification de Docker
# ---------------------------------------------------------------------------

info "Vérification de l'accès à Docker..."

if ! docker info >/dev/null 2>&1; then
    error "Docker n'est pas accessible sans sudo.
Appliquer le groupe docker avec : newgrp docker
Puis relancer le script."
fi

success "Docker est accessible."

# ---------------------------------------------------------------------------
# Vérification du port 8888
# ---------------------------------------------------------------------------

if ! k3d cluster list --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "${CLUSTER_NAME}"; then

    if ss -lnt 2>/dev/null | awk '{print $4}' \
        | grep -Eq "(^|:|\])${HOST_PORT}$"; then
        error "Le port ${HOST_PORT} est déjà utilisé par un autre processus."
    fi
fi

# ---------------------------------------------------------------------------
# Création du cluster
# ---------------------------------------------------------------------------

if k3d cluster list --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "${CLUSTER_NAME}"; then

    info "Le cluster '${CLUSTER_NAME}' existe déjà."
else
    info "Création du cluster K3d '${CLUSTER_NAME}'..."

    k3d cluster create "${CLUSTER_NAME}" \
        --servers 1 \
        --agents 0 \
        --port "${HOST_PORT}:${CLUSTER_HTTP_PORT}@loadbalancer" \
        --wait

    success "Le cluster '${CLUSTER_NAME}' a été créé."
fi

# ---------------------------------------------------------------------------
# Configuration de kubectl
# ---------------------------------------------------------------------------

info "Sélection du contexte kubectl '${KUBECTL_CONTEXT}'..."

kubectl config use-context "${KUBECTL_CONTEXT}" >/dev/null

# ---------------------------------------------------------------------------
# Vérification du cluster
# ---------------------------------------------------------------------------

info "Attente de la disponibilité des nœuds Kubernetes..."

kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=180s

info "Attente du démarrage de Traefik..."

kubectl rollout status \
    deployment/traefik \
    --namespace kube-system \
    --timeout=180s

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------

echo
success "Le cluster K3d est opérationnel."
echo

echo "Configuration :"
echo "  Nom du cluster     : ${CLUSTER_NAME}"
echo "  Contexte kubectl   : ${KUBECTL_CONTEXT}"
echo "  Port HTTP de la VM : ${HOST_PORT}"
echo "  Adresse de test    : http://localhost:${HOST_PORT}"

echo
echo "État du cluster :"
echo

k3d cluster list

echo
kubectl get nodes

echo
kubectl get pods --all-namespaces

echo
echo "Étapes de vérification :"
echo
echo "1. Vérifier le cluster K3d :"
echo
echo "   k3d cluster list"
echo
echo "2. Vérifier le nœud Kubernetes :"
echo
echo "   kubectl get nodes"
echo
echo "3. Vérifier les pods système :"
echo
echo "   kubectl get pods -A"
echo
echo "4. Vérifier les conteneurs Docker du cluster :"
echo
echo "   docker ps"
echo
echo "5. Vérifier le port exposé par K3d :"
echo
echo "   docker port k3d-${CLUSTER_NAME}-serverlb"
echo
echo "6. Tester le point d'entrée HTTP :"
echo
echo "   curl -i http://localhost:${HOST_PORT}"
echo
echo "[INFO] Une réponse HTTP 404 est normale tant qu'aucune application"
echo "[INFO] ni règle Ingress n'a encore été déployée."

echo
echo "Étape suivante :"
echo
echo "7. Installer Argo CD dans le cluster :"
echo
echo "   ./scripts/install-argocd.sh"
