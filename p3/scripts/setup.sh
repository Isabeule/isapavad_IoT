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
ARGOCD_TIMEOUT_SECS="600"
APP_TIMEOUT_SECS="600"
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
        log "Argo CD already present, re-applying the manifest (idempotent)"
    else
        log "Installing Argo CD (this pulls several hundred MB of images, be patient)"
    fi

    # --server-side: le CRD applicationsets depasse la taille max de
    # l'annotation last-applied-configuration en apply cote client.
    local attempt
    for attempt in 1 2 3; do
        if kubectl apply -n "$ARGOCD_NS" --server-side --force-conflicts \
                -f "$ARGOCD_MANIFEST"; then
            return 0
        fi
        warn "kubectl apply failed (attempt ${attempt}/3), retrying in 5s"
        sleep 5
    done
    die "could not apply the Argo CD manifest after 3 attempts."
}


wait_for_argocd() {
    local deadline now
    deadline=$(( $(date +%s) + ARGOCD_TIMEOUT_SECS ))

    log "Waiting for the Argo CD CRDs to be established"
    until kubectl wait --for=condition=Established \
            crd/applications.argoproj.io --timeout=30s >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] \
            || die "the Argo CD CRDs never became established."
        sleep 2
    done

    log "Waiting for the Argo CD deployments to be Available (up to ${ARGOCD_TIMEOUT_SECS}s)"
    until kubectl wait --for=condition=Available deploy --all \
            -n "$ARGOCD_NS" --timeout=30s >/dev/null 2>&1; do
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ]; then
            warn "Some deployments are still not Available. Current state:"
            kubectl get pods -n "$ARGOCD_NS" >&2 || true
            die  "Argo CD is not ready after ${ARGOCD_TIMEOUT_SECS}s (slow image pull?). Rerun this script."
        fi
        log "  ...still pulling/starting ($(( deadline - now ))s left)"
    done

    log "Waiting for the application controller"
    kubectl rollout status statefulset/argocd-application-controller \
        -n "$ARGOCD_NS" --timeout="${ARGOCD_TIMEOUT_SECS}s" >/dev/null \
        || die "the argocd-application-controller never became ready."

    skip "Argo CD is up"
}


deploy_application() {
    [ -f "$APP_MANIFEST" ] || die "application manifest not found: ${APP_MANIFEST}"

    log "Applying the Argo CD Application \"${APP_NAME}\""
    local attempt
    for attempt in 1 2 3; do
        kubectl apply -f "$APP_MANIFEST" && break
        [ "$attempt" -lt 3 ] || die "could not apply ${APP_MANIFEST}."
        warn "kubectl apply failed (attempt ${attempt}/3), retrying in 5s"
        sleep 5
    done

    log "Waiting for Argo CD to sync the app into \"${DEV_NS}\" (up to ${APP_TIMEOUT_SECS}s)"
    local deadline now
    deadline=$(( $(date +%s) + APP_TIMEOUT_SECS ))

    # Argo CD ne re-lit git que toutes les ~3 min : on force un refresh
    # tant que le Deployment n'est pas apparu dans dev.
    until kubectl get "deploy/${APP_NAME}" -n "$DEV_NS" >/dev/null 2>&1; do
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ]; then
            warn "Argo CD never created the app. Diagnose with:"
            warn "  kubectl describe application ${APP_NAME} -n ${ARGOCD_NS}"
            kubectl get application "$APP_NAME" -n "$ARGOCD_NS" >&2 || true
            die  "the application was not synced after ${APP_TIMEOUT_SECS}s."
        fi
        kubectl -n "$ARGOCD_NS" annotate application "$APP_NAME" \
            argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
        log "  ...waiting for the sync ($(( deadline - now ))s left)"
        sleep 10
    done

    log "Waiting for the ${APP_NAME} pod to be ready (image pull)"
    kubectl rollout status "deploy/${APP_NAME}" -n "$DEV_NS" \
            --timeout="${APP_TIMEOUT_SECS}s" >/dev/null \
        || die "the ${APP_NAME} deployment never became ready; check 'kubectl get pods -n ${DEV_NS}'."

    skip "Application \"${APP_NAME}\" is Synced and Running in \"${DEV_NS}\""
}

check_app_responds() {
    log "Checking that the app answers on http://localhost:${HOST_PORT}/"
    local deadline
    deadline=$(( $(date +%s) + 120 ))
    until curl -fsS "http://localhost:${HOST_PORT}/" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] \
            || die "no answer on port ${HOST_PORT}; check 'kubectl get svc -n ${DEV_NS}' and the k3d port mapping."
        sleep 5
    done
    skip "curl http://localhost:${HOST_PORT}/ -> $(curl -fsS "http://localhost:${HOST_PORT}/")"
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
    check_app_responds
    report
    show_admin_password

    echo
    log "Done. Open the Argo CD UI with:  ./ui.sh"
    log "  (or by hand: kubectl port-forward svc/argocd-server -n ${ARGOCD_NS} ${ARGOCD_UI_PORT}:443)"
}

main "$@"
