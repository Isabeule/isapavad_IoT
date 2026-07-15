#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"

readonly HOST_PORT="8888"

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

if [[ "${EUID}" -eq 0 ]]; then
    error "Ne pas exécuter setup.sh avec sudo."
fi

info "Reconstruction complète de l'environnement P3..."

"${SCRIPT_DIR}/clean.sh"
"${SCRIPT_DIR}/create-cluster.sh"
"${SCRIPT_DIR}/install-argocd.sh"

info "Attente du Deployment de l'application..."

for _ in $(seq 1 60); do
    if kubectl get deployment wil-playground \
        --namespace dev \
        >/dev/null 2>&1; then

        break
    fi

    sleep 5
done

kubectl rollout status \
    deployment/wil-playground \
    --namespace dev \
    --timeout=300s

info "Vérification HTTP de l'application..."

for _ in $(seq 1 60); do
    if response="$(
        curl -fsS "http://localhost:${HOST_PORT}/" 2>/dev/null
    )"; then

        echo "${response}"
        echo

        success "L'environnement P3 est entièrement opérationnel."

        echo
        echo "Namespaces :"
        echo

        kubectl get namespaces

        echo
        echo "Pods Argo CD :"
        echo

        kubectl get pods \
            --namespace argocd

        echo
        echo "Ressources de l'application :"
        echo

        kubectl get all \
            --namespace dev

        exit 0
    fi

    sleep 5
done

error "L'application ne répond pas sur http://localhost:${HOST_PORT}/"
