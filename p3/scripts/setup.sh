#!/usr/bin/env bash


set -euo pipefail

CLUSTER_NAME="iot"
HOST_PORT="8888"
SERVERS="1"
AGENTS="0"
RECREATE="false"

ARGOCD_NS="argocd"
DEV_NS="dev"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
ARGOCD_TIMEOUT="300s"
ARGOCD_UI_PORT="8080"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_MANIFEST="${SCRIPT_DIR}/../confs/application.yaml"
APP_NAME="wil-playground"

# -------------------------------------------------------------- fonctions ----

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--recreate] [--help]

  --recreate   Delete the existing "${CLUSTER_NAME}" cluster and build a fresh one.
  --help       Show this message.
EOF
}

check_prereqs() {
    local tool
    for tool in docker kubectl k3d; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "$tool not found. Run p3/scripts/install.sh first."
    done


    if ! docker info >/dev/null 2>&1; then
        warn "Cannot talk to the Docker daemon."
        die  "Log out and back in (or run 'newgrp docker'), then rerun this script."
    fi
}

cluster_exists() {
    k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1
}

cluster_running() {
    docker ps --format '{{.Names}}' | grep -qx "k3d-${CLUSTER_NAME}-server-0"
}


port_is_mapped() {
    docker port "k3d-${CLUSTER_NAME}-serverlb" 2>/dev/null \
        | grep -q "^${HOST_PORT}/tcp"
}

# ----------------------------------------------------------------- etapes ----

create_cluster() {
    if cluster_exists && [ "$RECREATE" = "true" ]; then
        log "Deleting the existing cluster \"${CLUSTER_NAME}\""
        k3d cluster delete "$CLUSTER_NAME"
    fi

    if cluster_exists; then
        skip "Cluster \"${CLUSTER_NAME}\" already exists"

        if ! cluster_running; then
            log "Cluster is stopped, starting it back"
            k3d cluster start "$CLUSTER_NAME"
        fi

        if ! port_is_mapped; then
            warn "Host port ${HOST_PORT} is NOT published on this cluster."
            warn "A port mapping can only be set at creation time."
            warn "Rerun with --recreate to rebuild the cluster with -p ${HOST_PORT}:${HOST_PORT}@loadbalancer."
        fi
        return 0
    fi

    log "Creating the k3d cluster \"${CLUSTER_NAME}\" (port ${HOST_PORT} -> loadbalancer)"
    k3d cluster create "$CLUSTER_NAME" \
        --servers "$SERVERS" \
        --agents "$AGENTS" \
        -p "${HOST_PORT}:${HOST_PORT}@loadbalancer" \
        --wait
}


setup_kubeconfig() {
    log "Merging the kubeconfig and switching context"
    k3d kubeconfig merge "$CLUSTER_NAME" \
        --kubeconfig-merge-default \
        --kubeconfig-switch-context >/dev/null
}

wait_for_nodes() {
    log "Waiting for the nodes to be Ready"
    kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null \
        || die "the nodes never became Ready; check 'kubectl get nodes' and 'docker ps'."
    skip "All nodes are Ready"
}

ensure_namespace() {
    local ns="$1"
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        skip "Namespace \"${ns}\" already exists"
    else
        log "Creating namespace \"${ns}\""
        kubectl create namespace "$ns"
    fi
}

install_argocd() {
    if kubectl get deployment argocd-server -n "$ARGOCD_NS" >/dev/null 2>&1; then
        skip "Argo CD is already installed in the \"${ARGOCD_NS}\" namespace"
        return 0
    fi

    log "Installing Argo CD (this pulls several hundred MB of images, be patient)"
    kubectl apply -n "$ARGOCD_NS" -f "$ARGOCD_MANIFEST"
}


wait_for_argocd() {
    log "Waiting for the Argo CD deployments to be Available (up to ${ARGOCD_TIMEOUT})"
    if ! kubectl wait --for=condition=Available deploy --all \
            -n "$ARGOCD_NS" --timeout="$ARGOCD_TIMEOUT" >/dev/null; then
        warn "Some deployments are still not Available."
        warn "On a slow link this is usually just the image pull. Check with:"
        warn "  kubectl get pods -n ${ARGOCD_NS}"
        warn "then rerun this script."
        die  "Argo CD is not ready yet."
    fi


    log "Waiting for the application controller"
    kubectl rollout status statefulset/argocd-application-controller \
        -n "$ARGOCD_NS" --timeout="$ARGOCD_TIMEOUT" >/dev/null \
        || die "the argocd-application-controller never became ready."

    skip "Argo CD is up"
}


deploy_application() {
    [ -f "$APP_MANIFEST" ] || die "application manifest not found: ${APP_MANIFEST}"

    log "Applying the Argo CD Application \"${APP_NAME}\""
    kubectl apply -f "$APP_MANIFEST"

    log "Waiting for Argo CD to sync the app into \"${DEV_NS}\" (git poll + image pull, up to ${ARGOCD_TIMEOUT})"
    if ! kubectl wait --for=condition=Available "deploy/${APP_NAME}" \
            -n "$DEV_NS" --timeout="$ARGOCD_TIMEOUT" >/dev/null 2>&1; then
        warn "The app is not Available yet. Argo CD polls git every ~3 min; check with:"
        warn "  kubectl get application ${APP_NAME} -n ${ARGOCD_NS}"
        warn "  kubectl get pods -n ${DEV_NS}"
        return 0
    fi
    skip "Application \"${APP_NAME}\" is Synced and Running in \"${DEV_NS}\""
}

show_admin_password() {
    local password
    if ! kubectl get secret argocd-initial-admin-secret -n "$ARGOCD_NS" >/dev/null 2>&1; then
        warn "No argocd-initial-admin-secret found."
        warn "Normal if the admin password was already changed from the UI."
        return 0
    fi

    password="$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d)"

    echo
    log "Argo CD login"
    printf '  user      admin\n'
    printf '  password  %s\n' "$password"
    printf '  get it again later with:\n'
    printf "    kubectl -n %s get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d\n" "$ARGOCD_NS"
    warn "Do not write this password into any file of the repo."
}

report() {
    echo
    log "Cluster"
    k3d cluster list "$CLUSTER_NAME"
    echo
    log "Context"
    printf '  %s\n' "$(kubectl config current-context)"
    echo
    log "Nodes"
    kubectl get nodes
    echo
    log "Namespaces"
    kubectl get ns
    echo
    log "Argo CD pods"
    kubectl get pods -n "$ARGOCD_NS"
    echo
    log "Dev pods"
    kubectl get pods -n "$DEV_NS"
    echo
    log "Containers"
    docker ps --filter "name=k3d-${CLUSTER_NAME}" --format '  {{.Names}}\t{{.Status}}'
    echo

    if port_is_mapped; then
        skip "Host port ${HOST_PORT} is published; http://localhost:${HOST_PORT}/ will reach the app in dev."
    fi
}

# ------------------------------------------------------------------- main ----

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --recreate|-r) RECREATE="true" ;;
            --help|-h)     usage; exit 0 ;;
            *)             usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    check_prereqs
    create_cluster
    setup_kubeconfig
    wait_for_nodes
    ensure_namespace "$ARGOCD_NS"
    ensure_namespace "$DEV_NS"
    install_argocd
    wait_for_argocd
    deploy_application
    report
    show_admin_password

    echo
    log "Done. Open the Argo CD UI with:  ./ui.sh"
    log "  (or by hand: kubectl port-forward svc/argocd-server -n ${ARGOCD_NS} ${ARGOCD_UI_PORT}:443)"
}

main "$@"
