# Inception of Things - P3

## Objectif

Cette partie du projet consiste à mettre en place une infrastructure GitOps basée sur Kubernetes en utilisant :

- Docker
- K3d
- K3s
- Argo CD
- GitHub

L'application devra être déployée automatiquement dans Kubernetes par Argo CD à partir d'un dépôt GitHub public.

---

## Architecture cible

```text
GitHub Repository
        │
        ▼
    Argo CD
        │
        ▼
   Kubernetes
      (K3d)
        │
        ▼
   Application
```

Deux namespaces devront être créés :

```text
argocd
dev
```

- `argocd` : héberge Argo CD.
- `dev` : héberge l'application déployée automatiquement.

---

## Arborescence

```text
p3/
├── README.md
├── confs
│   ├── argocd
│   ├── app
│   └── namespaces
└── scripts
    ├── install.sh
    ├── create_cluster.sh
    ├── install_argocd.sh
    └── deploy_app.sh
```

---

## Prérequis

- Ubuntu 22.04 LTS
- Connexion Internet
- Utilisateur disposant des droits sudo

---

## Installation des outils

Rendre le script exécutable :

```bash
chmod +x scripts/install.sh
```

Vérifier la syntaxe :

```bash
bash -n scripts/install.sh
```

Exécuter l'installation :

```bash
./scripts/install.sh
```

---

## Outils installés

Le script installe :

- Docker Engine
- kubectl
- K3d
- Argo CD CLI
- Git
- Curl
- jq

---

## Vérification

Contrôler les versions installées :

```bash
docker --version
kubectl version --client
k3d version
argocd version --client
git --version
curl --version
jq --version
```

---

## Création du cluster

À venir.

Script prévu :

```bash
./scripts/create_cluster.sh
```

---

## Installation d'Argo CD

À venir.

Script prévu :

```bash
./scripts/install_argocd.sh
```

---

## Déploiement de l'application

À venir.

Script prévu :

```bash
./scripts/deploy_app.sh
```

---

## Validation attendue

Vérification des namespaces :

```bash
kubectl get ns
```

Résultat attendu :

```text
NAME              STATUS
argocd            Active
dev               Active
```

Vérification des pods de l'application :

```bash
kubectl get pods -n dev
```

Vérification des pods Argo CD :

```bash
kubectl get pods -n argocd
```

---

## Workflow GitOps

1. Modification des manifests Kubernetes dans GitHub.
2. Commit et push vers le dépôt GitHub.
3. Détection automatique du changement par Argo CD.
4. Synchronisation du cluster.
5. Mise à jour automatique de l'application.

---

## Démonstration attendue

1. Modifier la version de l'application dans GitHub.
2. Effectuer un commit et un push.
3. Vérifier la synchronisation dans Argo CD.
4. Vérifier le déploiement de la nouvelle version dans Kubernetes.
5. Confirmer le changement de version de l'application.

---

## Références

- Kubernetes
- K3s
- K3d
- Argo CD
- Docker
- GitHub
