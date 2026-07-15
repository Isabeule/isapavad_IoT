#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="iot-cluster"
readonly KUBECTL_CONTEXT="k3d-${CLUSTER_NAME}"

readonly ARGOCD_NAMESPACE="argocd"
readonly DEV_NAMESPACE="dev"
readonly APPLICATION_NAME="iot-application"

readonly ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

readonly SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"

readonly P3_DIR="$(
    cd "${SCRIPT_DIR}/.." && pwd
)"

readonly REPOSITORY_ROOT="$(
    git -C "${P3_DIR}" rev-parse --show-toplevel 2>/dev/null
)"

readonly APPLICATION_TEMPLATE="${P3_DIR}/confs/argocd/application.yaml"

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

cluster_exists() {
    k3d cluster list --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | grep -Fxq "${CLUSTER_NAME}"
}

normalize_repository_url() {
    local url="$1"

    case "${url}" in
        git@github.com:*)
            printf 'https://github.com/%s\n' "${url#git@github.com:}"
            ;;

        ssh://git@github.com/*)
            printf 'https://github.com/%s\n' "${url#ssh://git@github.com/}"
            ;;

        https://github.com/*)
            printf '%s\n' "${url}"
            ;;

        *)
            error "Le dépôt Git doit être hébergé sur GitHub : ${url}"
            ;;
    esac
}

[[ -n "${REPOSITORY_ROOT}" ]] \
    || error "Ce projet doit être exécuté depuis un dépôt Git cloné."

[[ -f "${APPLICATION_TEMPLATE}" ]] \
    || error "Fichier absent : ${APPLICATION_TEMPLATE}"

cluster_exists \
    || error "Le cluster '${CLUSTER_NAME}' n'existe pas."

kubectl config use-context "${KUBECTL_CONTEXT}" >/dev/null

kubectl cluster-info >/dev/null 2>&1 \
    || error "Le cluster Kubernetes n'est pas accessible."

readonly RAW_REPOSITORY_URL="$(
    git -C "${REPOSITORY_ROOT}" remote get-url origin
)"

readonly REPOSITORY_URL="$(
    normalize_repository_url "${RAW_REPOSITORY_URL}"
)"

info "Dépôt GitHub utilisé par Argo CD : ${REPOSITORY_URL}"

git ls-remote "${REPOSITORY_URL}" HEAD >/dev/null 2>&1 \
    || error "Le dépôt GitHub n'est pas accessible publiquement."

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

info "Création des namespaces '${ARGOCD_NAMESPACE}' et '${DEV_NAMESPACE}'..."

kubectl create namespace "${ARGOCD_NAMESPACE}" \
    --dry-run=client \
    --output yaml \
    | kubectl apply --filename -

kubectl create namespace "${DEV_NAMESPACE}" \
    --dry-run=client \
    --output yaml \
    | kubectl apply --filename -

# ---------------------------------------------------------------------------
# Installation d'Argo CD
# ---------------------------------------------------------------------------

info "Installation d'Argo CD..."

kubectl apply \
    --server-side \
    --force-conflicts \
    --namespace "${ARGOCD_NAMESPACE}" \
    --filename "${ARGOCD_MANIFEST_URL}"

# ---------------------------------------------------------------------------
# Attente d'Argo CD
# ---------------------------------------------------------------------------

info "Attente des composants Argo CD..."

kubectl rollout status \
    deployment/argocd-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    deployment/argocd-repo-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    statefulset/argocd-application-controller \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl wait \
    --for=condition=Ready \
    pod \
    --all \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

# ---------------------------------------------------------------------------
# Création de l'Application Argo CD
# ---------------------------------------------------------------------------

info "Création de l'Application Argo CD..."

temporary_manifest="$(mktemp)"

trap 'rm -f "${temporary_manifest}"' EXIT

sed "s|__REPOSITORY_URL__|${REPOSITORY_URL}|g" \
    "${APPLICATION_TEMPLATE}" \
    > "${temporary_manifest}"

kubectl apply \
    --filename "${temporary_manifest}"

# ---------------------------------------------------------------------------
# Synchronisation GitOps
# ---------------------------------------------------------------------------

info "Attente de la synchronisation GitOps..."

for _ in $(seq 1 120); do
    sync_status="$(
        kubectl get application "${APPLICATION_NAME}" \
            --namespace "${ARGOCD_NAMESPACE}" \
            --output jsonpath='{.status.sync.status}' \
            2>/dev/null || true
    )"

    health_status="$(
        kubectl get application "${APPLICATION_NAME}" \
            --namespace "${ARGOCD_NAMESPACE}" \
            --output jsonpath='{.status.health.status}' \
            2>/dev/null || true
    )"

    if [[ "${sync_status}" == "Synced" \
        && "${health_status}" == "Healthy" ]]; then

        success "L'application Argo CD est Synced et Healthy."
        exit 0
    fi

    sleep 5
done

kubectl get application "${APPLICATION_NAME}" \
    --namespace "${ARGOCD_NAMESPACE}" \
    --output wide || true

error "Argo CD n'a pas atteint l'état Synced/Healthy dans le délai imparti."
