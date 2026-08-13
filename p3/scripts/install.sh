#!/usr/bin/env bash


set -euo pipefail

KUBECTL_INSTALL_DIR="/usr/local/bin"
K3D_INSTALL_URL="https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh"
DOCKER_INSTALL_URL="https://get.docker.com"

WORKDIR=""
KEEPALIVE_PID=""

# ------------------------------------------------------------- fonctions ----

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

is_root() { [ "$(id -u)" -eq 0 ]; }

as_root() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

cleanup() {
    if [ -n "$KEEPALIVE_PID" ]; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
    fi
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT


prime_sudo() {
    is_root && return 0
    command -v sudo >/dev/null 2>&1 || die "sudo not found; rerun this script as root."
    log "Asking for sudo up front (one prompt, nothing later)"
    sudo -v || die "sudo authentication failed."
    while true; do
        sudo -n true 2>/dev/null || break
        sleep 50
        kill -0 "$$" 2>/dev/null || break
    done &
    KEEPALIVE_PID=$!
}


detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armhf)   echo "arm" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    log "Installing curl"
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update -qq
        as_root apt-get install -y -qq curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y curl ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Sy --noconfirm curl ca-certificates
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper --non-interactive install curl ca-certificates
    else
        die "no known package manager; install curl by hand and rerun."
    fi
}


target_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

# ----------------------------------------------------------------- etapes ----


install_docker() {
    if command -v docker >/dev/null 2>&1; then
        skip "Docker already installed ($(docker --version))"
    else
        log "Installing Docker Engine from $DOCKER_INSTALL_URL"
        curl -fsSL "$DOCKER_INSTALL_URL" -o "$WORKDIR/get-docker.sh"
        as_root sh "$WORKDIR/get-docker.sh"
    fi


    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet docker && systemctl is-enabled --quiet docker; then
            skip "Docker service already enabled and running"
        else
            log "Enabling and starting the docker service"
            as_root systemctl enable --now docker
        fi
    else
        warn "No systemd detected; start the Docker daemon yourself (e.g. 'sudo dockerd &')."
    fi
}

add_user_to_docker_group() {
    local user
    user="$(target_user)"

    if ! getent group docker >/dev/null 2>&1; then
        log "Creating the docker group"
        as_root groupadd docker
    fi

    if [ "$user" = "root" ]; then
        warn "Running as root with no SUDO_USER; skipping the docker group step."
        return 0
    fi


    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        skip "$user is already in the docker group"
    else
        log "Adding $user to the docker group"
        as_root usermod -aG docker "$user"
    fi
}

install_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        skip "kubectl already installed ($(kubectl version --client 2>/dev/null | head -n1))"
        return 0
    fi

    local arch version base
    arch="$(detect_arch)"
    version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    [ -n "$version" ] || die "could not resolve the latest stable kubectl version."
    base="https://dl.k8s.io/release/${version}/bin/linux/${arch}"

    log "Installing kubectl $version ($arch)"
    curl -fsSL -o "$WORKDIR/kubectl" "${base}/kubectl"
    curl -fsSL -o "$WORKDIR/kubectl.sha256" "${base}/kubectl.sha256"

    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$WORKDIR" && printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check --quiet ) \
            || die "kubectl checksum mismatch."
    else
        warn "sha256sum not available; skipping checksum verification."
    fi

    as_root install -o root -g root -m 0755 "$WORKDIR/kubectl" "${KUBECTL_INSTALL_DIR}/kubectl"
}

install_k3d() {
    if command -v k3d >/dev/null 2>&1; then
        skip "k3d already installed ($(k3d version 2>/dev/null | head -n1))"
        return 0
    fi

    log "Installing k3d from $K3D_INSTALL_URL"
    curl -fsSL "$K3D_INSTALL_URL" -o "$WORKDIR/k3d-install.sh"
    as_root bash "$WORKDIR/k3d-install.sh"
}


install_argocd_cli() {
    if command -v argocd >/dev/null 2>&1; then
        skip "argocd CLI already installed ($(argocd version --client --short 2>/dev/null | head -n1))"
        return 0
    fi

    local arch base
    arch="$(detect_arch)"
    base="https://github.com/argoproj/argo-cd/releases/latest/download"

    log "Installing the argocd CLI ($arch)"
    curl -fsSL -o "$WORKDIR/argocd" "${base}/argocd-linux-${arch}"


    if command -v sha256sum >/dev/null 2>&1 \
        && curl -fsSL -o "$WORKDIR/cli_checksums.txt" "${base}/cli_checksums.txt"; then
        ( cd "$WORKDIR" \
            && grep " argocd-linux-${arch}$" cli_checksums.txt > argocd.sha256 \
            && sed -i "s| argocd-linux-${arch}$|  argocd|" argocd.sha256 \
            && sha256sum --check --quiet argocd.sha256 ) \
            || warn "could not verify the argocd checksum."
    else
        warn "sha256sum or the checksum file is not available; skipping verification."
    fi

    as_root install -o root -g root -m 0755 "$WORKDIR/argocd" "${KUBECTL_INSTALL_DIR}/argocd"
}

report() {
    local user
    user="$(target_user)"

    echo
    log "Installed versions"
    printf '  docker          %s\n' "$(docker --version 2>/dev/null || echo 'NOT FOUND')"
    printf '  docker compose  %s\n' "$(docker compose version 2>/dev/null || echo 'NOT FOUND')"
    printf '  kubectl         %s\n' "$(kubectl version --client 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    printf '  k3d             %s\n' "$(k3d version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    printf '  k3s (default)   %s\n' "$(k3d version 2>/dev/null | sed -n '2p' || echo 'NOT FOUND')"
    printf '  argocd CLI      %s\n' "$(argocd version --client --short 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    echo


    if [ "$user" != "root" ] && ! docker info >/dev/null 2>&1; then
        warn "Group membership is not active in this shell yet."
        warn "Log out and back in (or run 'newgrp docker') before using docker without sudo."
        warn "Then check it: docker run --rm hello-world"
    else
        skip "Docker is usable from this shell. Try: docker run --rm hello-world"
    fi
}

# ------------------------------------------------------------------- main ----

main() {
    [ "$(uname -s)" = "Linux" ] || die "this script targets Linux only."

    prime_sudo
    WORKDIR="$(mktemp -d)"

    ensure_curl
    install_docker
    add_user_to_docker_group
    install_kubectl
    install_k3d
    install_argocd_cli
    report

    log "Done."
}

main "$@"
