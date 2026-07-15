# Inception of Things — P3

## Arborescence
p3/
├── README.md
├── confs/
│   ├── app/
│   │   ├── deployment.yaml
│   │   ├── ingress.yaml
│   │   └── service.yaml
│   └── argocd/
│       └── application.yaml
└── scripts/
    ├── clean.sh
    ├── create-cluster.sh
    ├── install-argocd.sh
    ├── install.sh
    └── setup.sh


## Installation complète depuis un clone neuf
Depuis le dossier `p3` :
sudo ./scripts/install.sh && sg docker -c './scripts/setup.sh'


Cette commande :

1. installe Docker, kubectl et K3d ;
2. supprime un éventuel ancien cluster ;
3. crée un cluster K3d ;
4. crée les namespaces `argocd` et `dev` ;
5. installe Argo CD ;
6. configure Argo CD pour surveiller `p3/confs/app` ;
7. déploie automatiquement `wil42/playground:v1` ;
8. vérifie l'application sur `http://localhost:8888`.

## Vérifications
k3d cluster list
kubectl get nodes
kubectl get namespaces
kubectl get pods -n argocd
kubectl get all -n dev
kubectl get application -n argocd
curl http://localhost:8888/

Résultat initial attendu :
{"status":"ok", "message":"v1"}


## Démonstration GitOps : passage de v1 à v2
sed -i 's/wil42\/playground:v1/wil42\/playground:v2/' \
    confs/app/deployment.yaml

git add confs/app/deployment.yaml
git commit -m "Deploy application v2"
git push

Suivre la synchronisation :
kubectl get application -n argocd -w

Dans un autre terminal :
kubectl get pods -n dev -w

Puis vérifier :
curl http://localhost:8888/

Résultat attendu :
{"status":"ok", "message":"v2"}

Avant la soutenance, remettre et pousser :
image: wil42/playground:v1


## Nettoyage
./scripts/clean.sh

