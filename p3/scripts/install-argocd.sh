#!/usr/bin/env bash

set -Eeuo pipefail

readonly CLUSTER_NAME="iot-cluster"
readonly KUBECTL_CONTEXT="k3d-${CLUSTER_NAME}"

readonly ARGOCD_NAMESPACE="argocd"
readonly DEV_NAMESPACE="dev"

readonly ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

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

# ---------------------------------------------------------------------------
# Vérification des dépendances
# ---------------------------------------------------------------------------

info "Vérification des dépendances..."

command_exists kubectl \
    || error "kubectl n'est pas installé.
Exécuter d'abord : sudo ./scripts/install.sh"

command_exists k3d \
    || error "K3d n'est pas installé.
Exécuter d'abord : sudo ./scripts/install.sh"

# ---------------------------------------------------------------------------
# Vérification du cluster K3d
# ---------------------------------------------------------------------------

if ! k3d cluster list --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "${CLUSTER_NAME}"; then

    error "Le cluster '${CLUSTER_NAME}' n'existe pas.
Exécuter d'abord : ./scripts/create-cluster.sh"
fi

info "Sélection du contexte kubectl '${KUBECTL_CONTEXT}'..."

kubectl config use-context "${KUBECTL_CONTEXT}" >/dev/null

if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Le cluster Kubernetes n'est pas accessible."
fi

success "Le cluster Kubernetes est accessible."

# ---------------------------------------------------------------------------
# Création des namespaces
# ---------------------------------------------------------------------------

info "Création du namespace '${ARGOCD_NAMESPACE}'..."

kubectl create namespace "${ARGOCD_NAMESPACE}" \
    --dry-run=client \
    --output yaml \
    | kubectl apply --server-side --filename -

info "Création du namespace '${DEV_NAMESPACE}'..."

kubectl create namespace "${DEV_NAMESPACE}" \
    --dry-run=client \
    --output yaml \
    | kubectl apply --server-side --filename -

# ---------------------------------------------------------------------------
# Installation d'Argo CD
# ---------------------------------------------------------------------------

info "Installation d'Argo CD avec Server-Side Apply..."

kubectl apply \
    --server-side \
    --force-conflicts \
    --namespace "${ARGOCD_NAMESPACE}" \
    --filename "${ARGOCD_MANIFEST_URL}"

success "Les ressources Argo CD ont été appliquées."

# ---------------------------------------------------------------------------
# Attente du démarrage des composants
# ---------------------------------------------------------------------------

info "Attente du démarrage des composants Argo CD..."

kubectl rollout status \
    deployment/argocd-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    deployment/argocd-repo-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    deployment/argocd-dex-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    deployment/argocd-applicationset-controller \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    deployment/argocd-notifications-controller \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

kubectl rollout status \
    statefulset/argocd-application-controller \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

# ---------------------------------------------------------------------------
# Vérification des pods
# ---------------------------------------------------------------------------

info "Attente de la disponibilité des pods Argo CD..."

kubectl wait \
    --for=condition=Ready \
    pods \
    --all \
    --namespace "${ARGOCD_NAMESPACE}" \
    --timeout=300s

# ---------------------------------------------------------------------------
# Vérification des CRD Argo CD
# ---------------------------------------------------------------------------

info "Vérification des CustomResourceDefinitions Argo CD..."

kubectl get crd applications.argoproj.io >/dev/null
kubectl get crd applicationsets.argoproj.io >/dev/null
kubectl get crd appprojects.argoproj.io >/dev/null

success "Les CRD Argo CD sont disponibles."

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------

echo
success "Argo CD est installé et opérationnel."
echo

echo "Namespaces disponibles :"
echo

kubectl get namespaces

echo
echo "Pods Argo CD :"
echo

kubectl get pods \
    --namespace "${ARGOCD_NAMESPACE}" \
    --output wide

echo
echo "Déploiements Argo CD :"
echo

kubectl get deployments \
    --namespace "${ARGOCD_NAMESPACE}"

echo
echo "Services Argo CD :"
echo

kubectl get services \
    --namespace "${ARGOCD_NAMESPACE}"

echo
echo "CustomResourceDefinitions Argo CD :"
echo

kubectl get crd \
    | grep 'argoproj.io' || true

echo
echo "Étapes de vérification :"
echo

echo "1. Vérifier les namespaces :"
echo
echo "   kubectl get namespaces"
echo

echo "2. Vérifier les pods Argo CD :"
echo
echo "   kubectl get pods -n ${ARGOCD_NAMESPACE}"
echo

echo "3. Vérifier les déploiements Argo CD :"
echo
echo "   kubectl get deployments -n ${ARGOCD_NAMESPACE}"
echo

echo "4. Vérifier les services Argo CD :"
echo
echo "   kubectl get services -n ${ARGOCD_NAMESPACE}"
echo

echo "5. Vérifier les CRD Argo CD :"
echo
echo "   kubectl get crd | grep argoproj.io"
echo

echo "6. Suivre les pods en temps réel si nécessaire :"
echo
echo "   kubectl get pods -n ${ARGOCD_NAMESPACE} -w"
echo
echo "   Quitter l'affichage avec Ctrl+C."

echo
echo "Accès local à l'interface Argo CD :"
echo

echo "7. Ouvrir un second terminal et lancer :"
echo
echo "   kubectl port-forward \\"
echo "       service/argocd-server \\"
echo "       --namespace ${ARGOCD_NAMESPACE} \\"
echo "       8080:443"
echo

echo "8. Ouvrir ensuite dans le navigateur :"
echo
echo "   https://localhost:8080"
echo
echo "[INFO] Un avertissement de certificat est normal avec le certificat"
echo "[INFO] autosigné utilisé par défaut par Argo CD."

echo
echo "Identifiants Argo CD :"
echo

echo "9. Nom d'utilisateur :"
echo
echo "   admin"
echo

echo "10. Récupérer le mot de passe initial :"
echo
echo "   kubectl --namespace ${ARGOCD_NAMESPACE} get secret \\"
echo "       argocd-initial-admin-secret \\"
echo "       --output jsonpath=\"{.data.password}\" \\"
echo "       | base64 --decode && echo"
echo

echo "11. Se connecter avec le CLI Argo CD :"
echo
echo "   argocd login localhost:8080 \\"
echo "       --username admin \\"
echo "       --insecure"
echo
echo "[INFO] Le mot de passe sera demandé par la commande."

echo
echo "Étape suivante du projet :"
echo

echo "12. Créer les manifests Kubernetes de l'application wil42/playground :"
echo
echo "   confs/deployment.yaml"
echo "   confs/service.yaml"
echo "   confs/ingress.yaml"
echo

echo "13. Ajouter ces manifests dans le dépôt Git surveillé par Argo CD."
echo

echo "14. Créer une ressource Argo CD Application afin de synchroniser"
echo "    automatiquement le dépôt Git avec le namespace '${DEV_NAMESPACE}'."
