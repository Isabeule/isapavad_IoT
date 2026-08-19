#!/usr/bin/env bash

# Remet la machine a l'etat vierge : supprime k3d, k3s, kubectl, argocd,
# Docker (Engine + compose), Vagrant et toutes leurs donnees, pour pouvoir
# relancer install.sh proprement juste apres.

set -uo pipefail

CLUSTER_NAME="iot"
BIN_DIR="/usr/local/bin"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ASSUME_YES="false"
KEEPALIVE_PID=""

# -------------------------------------------------------------- fonctions ----

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [-y|--yes] [-h|--help]

Wipe EVERYTHING p1/p2/p3 ever put on this host, so install.sh can run on a
clean machine:

  - the k3d cluster "${CLUSTER_NAME}", every other k3d cluster/registry, all
    Docker containers, images, volumes and networks
  - k3s (host install, via its own uninstall scripts)
  - kubectl, k3d, argocd, docker-compose binaries and their config
    (~/.kube, ~/.k3d, ~/.config/k3d, ~/.config/argocd, ~/.docker)
  - Docker Engine + compose plugin, /var/lib/docker, /var/lib/containerd,
    /etc/docker, the docker apt/yum repo and the docker group
  - the p1/p2 Vagrant VMs, their libvirt domains/networks/volumes,
    the vagrant package and ~/.vagrant.d

  -y, --yes    Do not ask for confirmation.
  -h, --help   Show this message.
EOF
}

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

target_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

user_home() {
    getent passwd "$(target_user)" | cut -d: -f6
}

# docker/k3d ont besoin du socket docker : si l'utilisateur n'est pas (encore)
# dans le groupe docker, on passe par root.
docker_cmd() {
    if docker info >/dev/null 2>&1; then docker "$@"; else as_root docker "$@"; fi
}

k3d_cmd() {
    if docker info >/dev/null 2>&1; then k3d "$@"; else as_root k3d "$@"; fi
}

pkg_purge() {
    if command -v apt-get >/dev/null 2>&1; then
        # apt-get purge annule TOUT si un seul nom est inconnu :
        # on ne garde que les paquets connus de dpkg.
        local known
        known="$(dpkg-query -W -f='${Package}\n' "$@" 2>/dev/null)"
        [ -n "$known" ] || return 0
        # shellcheck disable=SC2086
        as_root apt-get purge -y -qq $known >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf remove -y "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        as_root yum remove -y "$@" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -Rns --noconfirm "$@" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper --non-interactive remove "$@" >/dev/null 2>&1
    else
        return 1
    fi
    return 0
}

confirm() {
    [ "$ASSUME_YES" = "true" ] && return 0

    echo
    warn "This will WIPE from this machine:"
    warn "  - every k3d cluster and ALL Docker containers/images/volumes"
    warn "  - k3s, kubectl, k3d, argocd, docker-compose and their config"
    warn "  - Docker Engine, /var/lib/docker, the docker group"
    warn "  - the p1/p2 VMs, their libvirt resources, and Vagrant itself"
    echo

    local answer
    read -r -p "Type 'yes' to continue: " answer
    [ "$answer" = "yes" ] || die "aborted."
}

# ------------------------------------------------- cluster / kube / argocd ----

delete_k3d_clusters() {
    command -v k3d >/dev/null 2>&1 || { skip "k3d is not installed, no cluster to delete"; return 0; }

    local clusters registries
    clusters="$(k3d_cmd cluster list --no-headers 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$clusters" ]; then
        log "Deleting the k3d clusters: $(echo "$clusters" | paste -sd' ' -)"
        # shellcheck disable=SC2086
        k3d_cmd cluster delete $clusters || warn "k3d could not delete every cluster cleanly."
    else
        skip "No k3d cluster"
    fi

    registries="$(k3d_cmd registry list --no-headers 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$registries" ]; then
        log "Deleting the k3d registries"
        # shellcheck disable=SC2086
        k3d_cmd registry delete $registries || warn "some registries could not be deleted."
    fi
}

remove_host_k3s() {
    local script found="false"
    for script in /usr/local/bin/k3s-agent-uninstall.sh /usr/local/bin/k3s-uninstall.sh; do
        if [ -x "$script" ]; then
            found="true"
            log "Running $script"
            as_root "$script" || warn "$script exited with an error."
        fi
    done
    [ "$found" = "false" ] && skip "No k3s installed on this host"
    as_root rm -rf /etc/rancher /var/lib/rancher 2>/dev/null || true
}

remove_kube_tools() {
    local home bin
    home="$(user_home)"

    for bin in kubectl k3d argocd; do
        if [ -e "${BIN_DIR}/${bin}" ]; then
            log "Removing ${BIN_DIR}/${bin}"
            as_root rm -f "${BIN_DIR}/${bin}"
        else
            skip "${bin} is not in ${BIN_DIR}"
        fi
    done

    local dir
    for dir in "${home}/.kube" "${home}/.k3d" "${home}/.config/k3d" "${home}/.config/argocd"; do
        if [ -e "$dir" ]; then
            log "Removing $dir"
            rm -rf "$dir"
        fi
    done
}

# ----------------------------------------------------------------- docker ----

remove_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Removing every remaining container, image, volume and network"
        local ids
        ids="$(docker_cmd ps -aq 2>/dev/null || true)"
        # shellcheck disable=SC2086
        [ -n "$ids" ] && docker_cmd rm -f $ids >/dev/null 2>&1 || true
        docker_cmd system prune -af --volumes >/dev/null 2>&1 || true
    fi

    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        log "Stopping and disabling the docker service"
        as_root systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
        as_root systemctl disable --now containerd.service >/dev/null 2>&1 || true
    fi

    log "Uninstalling the Docker packages"
    pkg_purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
              docker-compose-plugin docker-ce-rootless-extras \
              docker-model-plugin docker-scan-plugin \
              docker.io docker-compose docker-compose-v2 docker-doc podman-docker \
        || warn "No known package manager; remove the Docker packages by hand."
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get autoremove -y -qq >/dev/null 2>&1 || true
    fi

    local dir
    for dir in /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd; do
        if [ -d "$dir" ]; then
            log "Removing $dir"
            as_root rm -rf "$dir"
        fi
    done

    # standalone docker-compose (v1) et restes de la repo docker
    as_root rm -f "${BIN_DIR}/docker-compose" \
                  /etc/apt/sources.list.d/docker.list \
                  /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg \
                  /usr/share/keyrings/docker-archive-keyring.gpg \
                  /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true

    if getent group docker >/dev/null 2>&1; then
        log "Removing the docker group"
        as_root groupdel docker 2>/dev/null || warn "could not remove the docker group (still in use?)."
    else
        skip "No docker group"
    fi

    local home
    home="$(user_home)"
    [ -d "${home}/.docker" ] && { log "Removing ${home}/.docker"; rm -rf "${home}/.docker"; }

    return 0
}

# ---------------------------------------------------------------- vagrant ----

destroy_vagrant_part() {
    local part="$1" dir="${REPO_ROOT}/$1"

    [ -d "$dir" ] || { skip "No ${part} directory"; return 0; }

    if command -v vagrant >/dev/null 2>&1 && [ -f "${dir}/Vagrantfile" ]; then
        log "vagrant destroy in ${part}"
        ( cd "$dir" && vagrant destroy -f ) || warn "vagrant destroy failed in ${part}."
    fi

    if [ -d "${dir}/.vagrant" ]; then
        log "Removing ${part}/.vagrant"
        rm -rf "${dir}/.vagrant"
    fi

    [ -f "${dir}/node-token" ] && { log "Removing ${part}/node-token"; rm -f "${dir}/node-token"; }

    return 0
}

destroy_libvirt_leftovers() {
    command -v virsh >/dev/null 2>&1 || { skip "virsh not found, skipping libvirt cleanup"; return 0; }

    local vm vol
    for vm in $(virsh -c qemu:///system list --all --name 2>/dev/null | grep -E '^(p1|p2)_' || true); do
        log "Removing the libvirt domain $vm"
        virsh -c qemu:///system destroy "$vm" >/dev/null 2>&1 || true
        virsh -c qemu:///system undefine "$vm" --remove-all-storage >/dev/null 2>&1 || true
    done

    if virsh -c qemu:///system net-info p10 >/dev/null 2>&1; then
        log "Removing the libvirt network p10"
        virsh -c qemu:///system net-destroy p10 >/dev/null 2>&1 || true
        virsh -c qemu:///system net-undefine p10 >/dev/null 2>&1 || true
    else
        skip "No libvirt network p10"
    fi

    for vol in $(virsh -c qemu:///system vol-list --pool default 2>/dev/null | awk 'NR>2 {print $1}' | grep -E '^(p1|p2)_' || true); do
        log "Removing the orphan volume $vol"
        virsh -c qemu:///system vol-delete --pool default "$vol" >/dev/null 2>&1 || true
    done
}

remove_vagrant() {
    destroy_vagrant_part p1
    destroy_vagrant_part p2
    destroy_libvirt_leftovers

    if command -v vagrant >/dev/null 2>&1; then
        log "Uninstalling Vagrant"
        pkg_purge vagrant vagrant-libvirt >/dev/null 2>&1 || true
        # installation manuelle (zip HashiCorp) le cas echeant
        command -v vagrant >/dev/null 2>&1 && as_root rm -f "$(command -v vagrant)"
    else
        skip "Vagrant is not installed"
    fi

    local home
    home="$(user_home)"
    if [ -d "${home}/.vagrant.d" ]; then
        log "Removing ${home}/.vagrant.d (boxes, plugins)"
        rm -rf "${home}/.vagrant.d"
    fi
}

# ------------------------------------------------------------------ report ----

report() {
    echo
    log "State after cleanup (everything should be 'not installed')"
    printf '  docker          %s\n' "$(docker --version 2>/dev/null || echo 'not installed')"
    printf '  docker compose  %s\n' "$(docker compose version 2>/dev/null || echo 'not installed')"
    printf '  kubectl         %s\n' "$(kubectl version --client 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  k3d             %s\n' "$(k3d version 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  k3s             %s\n' "$(k3s --version 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  argocd CLI      %s\n' "$(argocd version --client --short 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  vagrant         %s\n' "$(vagrant --version 2>/dev/null || echo 'not installed')"
    if command -v virsh >/dev/null 2>&1; then
        printf '  p1/p2 domains   %s\n' "$(virsh -c qemu:///system list --all --name 2>/dev/null | grep -cE '^(p1|p2)_' || true)"
    fi
    echo
}

# ------------------------------------------------------------------- main ----

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y)  ASSUME_YES="true" ;;
            --help|-h) usage; exit 0 ;;
            *)         usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    [ "$(uname -s)" = "Linux" ] || die "this script targets Linux only."

    confirm
    prime_sudo

    # ordre: VMs d'abord (vagrant a besoin de ses binaires), puis le cluster
    # (k3d a besoin de docker), puis les outils, puis docker lui-meme.
    remove_vagrant
    delete_k3d_clusters
    remove_host_k3s
    remove_kube_tools
    remove_docker

    report

    log "Done. The machine is clean; run scripts/install.sh to reinstall."
    warn "You were removed from the docker group; log out and back in after install.sh."
}

main "$@"
