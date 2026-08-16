confs/

├── app1.yaml     → app1.com

├── app2.yaml     → app2.com (3 replicas)

├── app3.yaml     → tout le reste (default backend)

└── ingress.yaml  → la table de routage qui relie les 3 Services aux hosts






vagrant up --provider=libvirt 




virsh list --all # liste les machines virtuelles (domains). Vide = aucune VM définie sur cet hyperviseur.

 Id   Name   State

--------------------

virsh net-list --all #liste les réseaux virtuels libvirt (essentiellement des switches virtuels + DHCP). Vide = aucun réseau défini, pas même le réseau default.

vagrant destroy -f # destroy vagrant env

virsh console <nom_de_la_vm>

vagrant up --debug 2>&1 | tee vagrant-debug.log







sudo ip -s link show vnet6                            

sudo tail -100 /var/log/libvirt/qemu/p2_default.log

sudo virsh -c qemu:///system screenshot p2_default /tmp/boot.ppm





open /tmp/boot.ppm





VAGRANT_LOG=debug vagrant up --provider=libvirt 2>&1 | tee vagrant-debug.log




 Fiche Checklist Finale : Inception-of-Things (Part 2)📁 ÉTAPE 1 : Sur la machine HÔTE (Vérification des fichiers)Allez dans votre dossier p2 et ouvrez le fichier :bashcat Vagrantfile
Utilisez le code avec précaution.[ ] Une seule VM : Pas de blocs config.vm.define.[ ] OS Stable : La ligne config.vm.box cible un OS stable (Ubuntu, Debian...).[ ] IP Demandée : Présence de config.vm.network "private_network", ip: "192.168.56.110".[ ] Nom de la VM : La ligne config.vm.hostname contient [votre_login]S.🖥️ ÉTAPE 2 : Sur la machine HÔTE (Pour le Navigateur)Pour que votre navigateur web puisse ouvrir http://app1.com, vous devez modifier le fichier hosts de votre vrai ordinateur [⚠️, 🌐] :bash# 1. Ouvrir le fichier hosts de votre ordinateur (Mac/Linux)
sudo nano /etc/hosts

# 2. Ajouter cette ligne tout en bas du fichier, puis sauvegarder :
192.168.56.110  app1.com app2.com app3.com
Utilisez le code avec précaution.💻 ÉTAPE 3 : Connexion & Réseau (Dans la VM)Démarrez la machine et connectez-vous en SSH :bashvagrant up
vagrant ssh
Utilisez le code avec précaution.Une fois dans la VM, validez le système :bash# 1. Le nom de la machine (Doit afficher : [votre_login]S)
hostname

# 2. L'IP de l'interface (Doit afficher l'IP du sujet)
ip a show $(ip route | grep default | awk '{print $5}')
Utilisez le code avec précaution.⎈ ÉTAPE 4 : K3s & Applications (Dans la VM)Activez l'alias temporaire pour utiliser les commandes de la grille de correction :bashalias kubectl="sudo k3s kubectl"

# 1. Vérifier le nœud Master (Statut : Ready / Nom : [votre_login]S)
kubectl get nodes -o wide

# 2. Vérifier les applications (Doit lister vos 3 pods, services et deploys)
kubectl get all
Utilisez le code avec précaution.🌐 ÉTAPE 5 : L'Ingress et les Tests (VM + Navigateur)Montrez le routage par nom de domaine [🌐] :bash# 1. Voir la configuration de l'Ingress (la commande secrète)
kubectl get ingress
Utilisez le code avec précaution.Test 1 : En ligne de commande (Dans la VM ou sur l'Hôte)bashcurl -H "Host: app1.com" http://192.168.56.110
curl -H "Host: app2.com" http://192.168.56.110
curl -H "Host: app3.com" http://192.168.56.110
Utilisez le code avec précaution.Test 2 : Dans le navigateur (Sur l'Hôte grâce à l'Étape 2)Ouvrez votre navigateur et entrez séparément :http://app1.comhttp://app2.comhttp://app3.comChaque URL doit afficher graphiquement une page différente (this is app-one, this is app-two, etc.) [💡].