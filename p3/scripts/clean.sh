#!/usr/bin/env bash


set -euo pipefail

CLUSTER_NAME="iot"
ARGOCD_NS="argocd"
DEV_NS="dev"
KUBECTL_INSTALL_DIR="/usr/local/bin"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DO_CLUSTER="true"
DO_TOOLS="false"
DO_DOCKER="false"
DO_VAGRANT="false"
ASSUME_YES="false"

KEEPALIVE_PID=""

# -------------------------------------------------------------- fonctions ----

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Undo what p3 built. With no option only the cluster and the local kube state go
away; everything that touches the host is opt-in.

  (default)    Delete the k3d cluster "${CLUSTER_NAME}", its containers, volumes and
               kubeconfig entries.
  --tools      Also remove kubectl, k3d and the argocd CLI from ${KUBECTL_INSTALL_DIR},
               plus their config directories (~/.k3d, ~/.config/k3d, ~/.config/argocd).
  --docker     Also uninstall Docker Engine, wipe /var/lib/docker and drop the
               docker group. Destroys every image and container on this host.
  --vagrant    Also destroy the p1/p2 Vagrant VMs, their libvirt domains,
               networks, volumes and local .vagrant state.
  --all        --tools --docker --vagrant.
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

confirm() {
    [ "$ASSUME_YES" = "true" ] && return 0

    echo
    warn "About to remove:"
    [ "$DO_CLUSTER" = "true" ] && printf '    - the k3d cluster "%s" and its kubeconfig entries\n' "$CLUSTER_NAME"
    [ "$DO_TOOLS"   = "true" ] && printf '    - kubectl, k3d, argocd and their config directories\n'
    [ "$DO_DOCKER"  = "true" ] && printf '    - Docker Engine, ALL images/containers/volumes on this host\n'
    [ "$DO_VAGRANT" = "true" ] && printf '    - the p1/p2 Vagrant VMs and their libvirt resources\n'
    echo

    local answer
    read -r -p "Type 'yes' to continue: " answer
    [ "$answer" = "yes" ] || die "aborted."
}

# ---------------------------------------------------------------- cluster ----

delete_cluster() {
    if ! command -v k3d >/dev/null 2>&1; then
        skip "k3d is not installed, no cluster to delete"
        return 0
    fi

    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        log "Deleting the k3d cluster \"${CLUSTER_NAME}\""
        k3d cluster delete "$CLUSTER_NAME" || warn "k3d could not delete the cluster cleanly."
    else
        skip "No k3d cluster named \"${CLUSTER_NAME}\""
    fi


    local registries
    registries="$(k3d registry list --no-headers 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$registries" ]; then
        log "Deleting the k3d registries"
        # shellcheck disable=SC2086
        k3d registry delete $registries || warn "some registries could not be deleted."
    fi
}

delete_leftover_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    local containers volumes networks

    containers="$(docker ps -aq --filter "name=k3d-${CLUSTER_NAME}" || true)"
    if [ -n "$containers" ]; then
        log "Removing the leftover k3d containers"
        # shellcheck disable=SC2086
        docker rm -f $containers >/dev/null
    else
        skip "No leftover k3d container"
    fi

    volumes="$(docker volume ls -q --filter "name=k3d-${CLUSTER_NAME}" || true)"
    if [ -n "$volumes" ]; then
        log "Removing the k3d volumes"
        # shellcheck disable=SC2086
        docker volume rm $volumes >/dev/null
    else
        skip "No leftover k3d volume"
    fi

    networks="$(docker network ls -q --filter "name=k3d-${CLUSTER_NAME}" || true)"
    if [ -n "$networks" ]; then
        log "Removing the k3d networks"
        # shellcheck disable=SC2086
        docker network rm $networks >/dev/null 2>&1 || true
    else
        skip "No leftover k3d network"
    fi
}

clean_kubeconfig() {
    command -v kubectl >/dev/null 2>&1 || return 0

    local ctx="k3d-${CLUSTER_NAME}"

    if kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
        log "Removing the kubeconfig entries for \"${ctx}\""
        kubectl config delete-context "$ctx"  >/dev/null 2>&1 || true
        kubectl config delete-cluster "$ctx"  >/dev/null 2>&1 || true
        kubectl config unset "users.admin@${ctx}" >/dev/null 2>&1 || true
    else
        skip "No kubeconfig context named \"${ctx}\""
    fi


    if [ "$(kubectl config current-context 2>/dev/null || true)" = "$ctx" ]; then
        kubectl config unset current-context >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------ tools ----

remove_host_k3s() {
    local script
    for script in /usr/local/bin/k3s-agent-uninstall.sh /usr/local/bin/k3s-uninstall.sh; do
        if [ -x "$script" ]; then
            log "Running $script (k3s was installed on this host, not only in k3d)"
            as_root "$script" || warn "$script exited with an error."
        fi
    done
}

remove_tools() {
    local home bin
    home="$(user_home)"

    for bin in kubectl argocd; do
        if [ -e "${KUBECTL_INSTALL_DIR}/${bin}" ]; then
            log "Removing ${KUBECTL_INSTALL_DIR}/${bin}"
            as_root rm -f "${KUBECTL_INSTALL_DIR}/${bin}"
        else
            skip "${bin} is not in ${KUBECTL_INSTALL_DIR}"
        fi
    done


    if [ -e "${KUBECTL_INSTALL_DIR}/k3d" ]; then
        log "Removing ${KUBECTL_INSTALL_DIR}/k3d"
        as_root rm -f "${KUBECTL_INSTALL_DIR}/k3d"
    else
        skip "k3d is not in ${KUBECTL_INSTALL_DIR}"
    fi


    local dir
    for dir in "${home}/.k3d" "${home}/.config/k3d" "${home}/.config/argocd" "${home}/.kube/cache"; do
        if [ -d "$dir" ]; then
            log "Removing $dir"
            rm -rf "$dir"
        fi
    done

    remove_host_k3s
}

# ----------------------------------------------------------------- docker ----

remove_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        skip "Docker is not installed"
    else
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            log "Stopping and disabling the docker service"
            as_root systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
            as_root systemctl disable --now containerd.service >/dev/null 2>&1 || true
        fi

        log "Uninstalling the Docker packages"
        local pkgs="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras"
        if command -v apt-get >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            as_root apt-get purge -y -qq $pkgs >/dev/null 2>&1 || warn "apt-get purge failed for some packages."
            as_root apt-get autoremove -y -qq >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            as_root dnf remove -y $pkgs >/dev/null 2>&1 || warn "dnf remove failed for some packages."
        elif command -v yum >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            as_root yum remove -y $pkgs >/dev/null 2>&1 || warn "yum remove failed for some packages."
        elif command -v pacman >/dev/null 2>&1; then
            as_root pacman -Rns --noconfirm docker docker-compose >/dev/null 2>&1 || warn "pacman remove failed."
        elif command -v zypper >/dev/null 2>&1; then
            as_root zypper --non-interactive remove docker docker-compose >/dev/null 2>&1 || warn "zypper remove failed."
        else
            warn "No known package manager; remove the Docker packages by hand."
        fi
    fi


    local dir
    for dir in /var/lib/docker /var/lib/containerd /etc/docker; do
        if [ -d "$dir" ]; then
            log "Removing $dir"
            as_root rm -rf "$dir"
        fi
    done

    as_root rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc \
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
    for vm in $(virsh list --all --name 2>/dev/null | grep -E '^(p1|p2)_' || true); do
        log "Removing the libvirt domain $vm"
        virsh destroy "$vm" >/dev/null 2>&1 || true
        virsh undefine "$vm" --remove-all-storage >/dev/null 2>&1 || true
    done


    if virsh net-info p10 >/dev/null 2>&1; then
        log "Removing the libvirt network p10"
        virsh net-destroy p10 >/dev/null 2>&1 || true
        virsh net-undefine p10 >/dev/null 2>&1 || true
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
}

# ------------------------------------------------------------------ report ----

report() {
    echo
    log "State after cleanup"

    printf '  docker          %s\n' "$(docker --version 2>/dev/null || echo 'not installed')"
    printf '  kubectl         %s\n' "$(kubectl version --client 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  k3d             %s\n' "$(k3d version 2>/dev/null | head -n1 || echo 'not installed')"
    printf '  argocd CLI      %s\n' "$(argocd version --client --short 2>/dev/null | head -n1 || echo 'not installed')"

    if command -v k3d >/dev/null 2>&1; then
        local clusters
        clusters="$(k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | paste -sd' ' - || true)"
        printf '  k3d clusters    %s\n' "${clusters:-none}"
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local left
        left="$(docker ps -aq --filter "name=k3d-${CLUSTER_NAME}" | wc -l)"
        printf '  k3d containers  %s\n' "$left"
    fi

    if [ "$DO_VAGRANT" = "true" ] && command -v virsh >/dev/null 2>&1; then
        printf '  p1/p2 domains   %s\n' "$(virsh list --all --name 2>/dev/null | grep -E '^(p1|p2)_' | wc -l)"
    fi
    echo
}

# ------------------------------------------------------------------- main ----

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --tools)     DO_TOOLS="true" ;;
            --docker)    DO_DOCKER="true" ;;
            --vagrant)   DO_VAGRANT="true" ;;
            --all|-a)    DO_TOOLS="true"; DO_DOCKER="true"; DO_VAGRANT="true" ;;
            --yes|-y)    ASSUME_YES="true" ;;
            --help|-h)   usage; exit 0 ;;
            *)           usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    [ "$(uname -s)" = "Linux" ] || die "this script targets Linux only."

    confirm

    if [ "$DO_TOOLS" = "true" ] || [ "$DO_DOCKER" = "true" ]; then
        prime_sudo
    fi

    if [ "$DO_CLUSTER" = "true" ]; then
        delete_cluster
        delete_leftover_containers
        clean_kubeconfig
    fi

    [ "$DO_VAGRANT" = "true" ] && remove_vagrant
    [ "$DO_TOOLS"   = "true" ] && remove_tools
    [ "$DO_DOCKER"  = "true" ] && remove_docker

    report

    log "Done."
    if [ "$DO_DOCKER" = "true" ]; then
        warn "You were removed from the docker group; log out and back in to refresh your session."
    fi
}

main "$@"
