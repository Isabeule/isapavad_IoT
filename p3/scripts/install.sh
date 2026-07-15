#!/usr/bin/env bash

set -Eeuo pipefail

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

on_error() {
    local exit_code=$?
    local line_number=$1

    printf '[ERROR] Échec du script à la ligne %s.\n' "${line_number}" >&2
    exit "${exit_code}"
}

trap 'on_error ${LINENO}' ERR

if [[ "${EUID}" -ne 0 ]]; then
    error "Exécuter ce script avec sudo : sudo ./scripts/install.sh"
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    error "Lancer le script avec sudo depuis un compte utilisateur non-root."
fi

readonly TARGET_USER="${SUDO_USER}"

if [[ ! -f /etc/os-release ]]; then
    error "Impossible d'identifier le système d'exploitation."
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    error "Ce script est prévu pour Ubuntu."
fi

readonly ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
    amd64)
        KUBECTL_ARCH="amd64"
        ;;
    arm64)
        KUBECTL_ARCH="arm64"
        ;;
    *)
        error "Architecture non prise en charge : ${ARCH}"
        ;;
esac

export DEBIAN_FRONTEND=noninteractive

info "Installation des dépendances système..."

apt-get update -y

apt-get install -y \
    ca-certificates \
    curl \
    git \
    gnupg

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

if command_exists docker; then
    info "Docker est déjà installé."
else
    info "Installation de Docker depuis le dépôt officiel..."

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update -y

    apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
fi

info "Activation du service Docker..."

systemctl enable --now docker

systemctl is-active --quiet docker \
    || error "Le service Docker n'est pas actif."

if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -Fxq docker; then
    info "L'utilisateur '${TARGET_USER}' appartient déjà au groupe docker."
else
    info "Ajout de '${TARGET_USER}' au groupe docker..."
    usermod -aG docker "${TARGET_USER}"
fi

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------

if command_exists kubectl; then
    info "kubectl est déjà installé."
else
    info "Installation de la dernière version stable de kubectl..."

    readonly KUBECTL_VERSION="$(
        curl -fsSL https://dl.k8s.io/release/stable.txt
    )"

    readonly KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"

    curl -fsSLo /tmp/kubectl "${KUBECTL_URL}"
    curl -fsSLo /tmp/kubectl.sha256 "${KUBECTL_URL}.sha256"

    echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" \
        | sha256sum --check -

    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

    rm -f \
        /tmp/kubectl \
        /tmp/kubectl.sha256
fi

# ---------------------------------------------------------------------------
# K3d
# ---------------------------------------------------------------------------

if command_exists k3d; then
    info "K3d est déjà installé."
else
    info "Installation de K3d..."

    curl -fsSL \
        https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
        | bash
fi

# ---------------------------------------------------------------------------
# Vérifications
# ---------------------------------------------------------------------------

command_exists docker \
    || error "Docker n'a pas été installé."

command_exists kubectl \
    || error "kubectl n'a pas été installé."

command_exists k3d \
    || error "K3d n'a pas été installé."

echo

success "Les outils nécessaires sont installés."

echo
echo "Versions installées :"
echo

docker --version
kubectl version --client
k3d version

echo
echo "Commande suivante, depuis le dossier p3 :"
echo
echo "  sg docker -c './scripts/setup.sh'"
echo
echo "Installation complète en une seule ligne :"
echo
echo "  sudo ./scripts/install.sh && sg docker -c './scripts/setup.sh'"
