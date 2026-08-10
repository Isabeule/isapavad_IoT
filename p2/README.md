confs/
├── app1.yaml     → app1.com
├── app2.yaml     → app2.com (3 replicas)
├── app3.yaml     → tout le reste (default backend)
└── ingress.yaml  → la table de routage qui relie les 3 Services aux hosts



vagrant up --provider=libvirt 

virsh list --all # list all env vagrant
 Id   Name   State
--------------------
virsh net-list --all
vagrant destroy -f # destroy vagrant env
virsh console <nom_de_la_vm>
vagrant up --debug 2>&1 | tee vagrant-debug.log