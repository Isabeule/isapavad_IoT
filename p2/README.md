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