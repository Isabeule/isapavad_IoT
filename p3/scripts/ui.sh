#!/usr/bin/env bash


set -euo pipefail

ARGOCD_NS="argocd"
LOCAL_PORT="8080"
ONCE="false"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merr\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--port N] [--once] [--help]

  --port N   Local port for the Argo CD UI (default ${LOCAL_PORT}).
  --once     Do not restart the port-forward if it dies.
  --help     Show this message.
EOF
}

check_argocd() {
    command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Run install.sh first."

    kubectl get namespace "$ARGOCD_NS" >/dev/null 2>&1 \
        || die "namespace \"${ARGOCD_NS}\" not found. Run ./setup.sh first."

    kubectl get svc argocd-server -n "$ARGOCD_NS" >/dev/null 2>&1 \
        || die "service argocd-server not found. Run ./setup.sh first."

    if ! kubectl wait --for=condition=Available deploy/argocd-server \
            -n "$ARGOCD_NS" --timeout=60s >/dev/null 2>&1; then
        warn "argocd-server is not Available yet, the UI may take a moment."
    fi
}

print_credentials() {
    local password
    echo
    log "Argo CD UI"
    printf '  url       https://localhost:%s\n' "$LOCAL_PORT"
    printf '  user      admin\n'

    if kubectl get secret argocd-initial-admin-secret -n "$ARGOCD_NS" >/dev/null 2>&1; then
        password="$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' | base64 -d)"
        printf '  password  %s\n' "$password"
    else
        printf '  password  (initial secret is gone, use the one you set in the UI)\n'
    fi

    echo
    printf '  the browser will complain about the self-signed certificate, that is expected.\n'
    printf '  argocd CLI:  argocd login localhost:%s --username admin --insecure\n' "$LOCAL_PORT"
    echo
}

forward() {
    kubectl port-forward "svc/argocd-server" -n "$ARGOCD_NS" "${LOCAL_PORT}:443"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --port|-p) shift; [ $# -gt 0 ] || die "--port needs a value."; LOCAL_PORT="$1" ;;
            --once)    ONCE="true" ;;
            --help|-h) usage; exit 0 ;;
            *)         usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    check_argocd
    print_credentials

    log "Port-forwarding svc/argocd-server ${LOCAL_PORT} -> 443 (Ctrl-C to stop)"

    if [ "$ONCE" = "true" ]; then
        forward
        return 0
    fi

    while true; do
        forward || true
        warn "Port-forward died, restarting in 2s. Ctrl-C to give up."
        sleep 2
    done
}

main "$@"
