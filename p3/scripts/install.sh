#!/usr/bin/env bash

set -Eeuo pipefail

readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
readonly DOCKER_REPOSITORY="/etc/apt/sources.list.d/docker.list"

readonly KUBERNETES_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
readonly KUBERNETES_REPOSITORY="/etc/apt/sources.list.d/kubernetes.list"

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

if [[ "${EUID}" -ne 0 ]]; then
    error "Ce script doit être exécuté avec sudo : sudo ./scripts/install.sh"
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    error "Le script doit être lancé avec sudo depuis un compte utilisateur non-root."
fi

readonly TARGET_USER="${SUDO_USER}"

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
    error "L'utilisateur '${TARGET_USER}' est introuvable."
fi

if [[ ! -f /etc/os-release ]]; then
    error "Impossible d'identifier le système d'exploitation."
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    error "Ce script est prévu pour Ubuntu."
fi

readonly SYSTEM_ARCHITECTURE="$(dpkg --print-architecture)"

case "${SYSTEM_ARCHITECTURE}" in
    amd64)
        ARGOCD_ARCHITECTURE="amd64"
        ;;
    arm64)
        ARGOCD_ARCHITECTURE="arm64"
        ;;
    *)
        error "Architecture non prise en charge : ${SYSTEM_ARCHITECTURE}"
        ;;
esac

export DEBIAN_FRONTEND=noninteractive

info "Mise à jour de l'index des paquets..."
apt-get update -y

info "Installation des dépendances système..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    git \
    gnupg \
    lsb-release \
    software-properties-common \
    wget

install -m 0755 -d /etc/apt/keyrings

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

if command_exists docker; then
    info "Docker est déjà installé."
else
    info "Configuration du dépôt officiel Docker..."

    rm -f "${DOCKER_KEYRING}"

    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
        | gpg --dearmor -o "${DOCKER_KEYRING}"

    chmod a+r "${DOCKER_KEYRING}"

    cat > "${DOCKER_REPOSITORY}" <<EOF
deb [arch=${SYSTEM_ARCHITECTURE} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

    apt-get update -y

    info "Installation de Docker..."
    apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
fi

info "Activation du service Docker..."
systemctl enable --now docker

if ! systemctl is-active --quiet docker; then
    error "Le service Docker n'est pas actif."
fi

info "Ajout de l'utilisateur '${TARGET_USER}' au groupe docker..."

if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -Fxq "docker"; then
    info "L'utilisateur appartient déjà au groupe docker."
else
    usermod -aG docker "${TARGET_USER}"
    success "L'utilisateur a été ajouté au groupe docker."
fi

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------

if command_exists kubectl; then
    info "kubectl est déjà installé."
else
    info "Configuration du dépôt officiel Kubernetes..."

    rm -f "${KUBERNETES_KEYRING}"

    curl -fsSL \
        "https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key" \
        | gpg --dearmor -o "${KUBERNETES_KEYRING}"

    chmod a+r "${KUBERNETES_KEYRING}"

    cat > "${KUBERNETES_REPOSITORY}" <<EOF
deb [signed-by=${KUBERNETES_KEYRING}] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /
EOF

    apt-get update -y

    info "Installation de kubectl..."
    apt-get install -y kubectl
fi

# ---------------------------------------------------------------------------
# K3d
# ---------------------------------------------------------------------------

if command_exists k3d; then
    info "K3d est déjà installé."
else
    info "Installation de K3d..."

    curl -fsSL \
        "https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh" \
        | bash
fi

# ---------------------------------------------------------------------------
# Argo CD CLI
# ---------------------------------------------------------------------------

if command_exists argocd; then
    info "Le CLI Argo CD est déjà installé."
else
    info "Installation du CLI Argo CD..."

    curl -fsSL \
        -o /usr/local/bin/argocd \
        "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARGOCD_ARCHITECTURE}"

    chmod 0755 /usr/local/bin/argocd
fi

# ---------------------------------------------------------------------------
# Vérifications
# ---------------------------------------------------------------------------

info "Vérification des outils installés..."

command_exists docker || error "Docker n'a pas été correctement installé."
command_exists kubectl || error "kubectl n'a pas été correctement installé."
command_exists k3d || error "K3d n'a pas été correctement installé."
command_exists argocd || error "Le CLI Argo CD n'a pas été correctement installé."

echo
success "Installation terminée."
echo

echo "Versions installées :"
echo

docker --version
kubectl version --client
k3d version
argocd version --client

echo
echo "Étapes suivantes :"
echo
echo "1. Appliquer le groupe docker dans le terminal actuel :"
echo
echo "   newgrp docker"
echo
echo "2. Vérifier l'accès à Docker sans sudo :"
echo
echo "   docker info"
echo "   docker run --rm hello-world"
echo
echo "3. Revenir dans le dossier p3 si nécessaire :"
echo
echo "   cd ~/Inception-of-Things/p3"
echo
echo "4. Créer le cluster K3d :"
echo
echo "   ./scripts/create-cluster.sh"
echo
echo "5. Vérifier le cluster :"
echo
echo "   k3d cluster list"
echo "   kubectl get nodes"
echo "   kubectl get pods -A"
echo "   docker ps"
echo
echo "6. Tester le point d'entrée HTTP du cluster :"
echo
echo "   curl -i http://localhost:8888"
echo
echo "[INFO] Une réponse HTTP 404 est normale tant qu'aucune application"
echo "[INFO] ni règle Ingress n'a encore été déployée."
