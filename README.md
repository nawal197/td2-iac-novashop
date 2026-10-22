# TD2 – Industrialiser K3s avec Terraform, Ansible et Helm

**Étudiante :** Nawal ICHENE – Filière STI – ASL AI (5ᵉ année, Architecture logicielle)
**Projet :** NovaShop, application 3-tiers (frontend nginx, API Python, PostgreSQL) déployée sur un cluster K3s mono-nœud hébergé sur OpenStack (DevStack, projet `asl-project`).

L'objectif est de passer du déploiement manuel du TD1 à un pipeline **reproductible et déclaratif** :

| Étape | Outil | Rôle |
|---|---|---|
| Provisionnement | **Terraform** | Security Group, VM, IP flottante |
| Configuration | **Ansible** | Prérequis système, installation de K3s, récupération du kubeconfig |
| Déploiement applicatif | **Helm** | 3 charts indépendants : `postgres`, `backend`, `frontend` |

---

## Architecture

```
┌── Hôte DevStack (poste IaC) ────────────┐
│  Terraform · Ansible · Helm · kubectl   │
└─────────────────────────────────────────┘
      │ Ansible (SSH :22)      │ Helm / kubectl (tunnel SSH → :6443)
      ▼                        ▼
┌── VM K3s mono-nœud (OpenStack) ─────────┐
│  IP privée    : 10.10.10.129            │
│  IP flottante : 172.24.4.142            │
│  ┌── Cluster K3s [namespace td2] ─────┐ │
│  │  Frontend nginx ×2                 │ │
│  │  Backend Python ×2                 │ │
│  │  PostgreSQL (StatefulSet + PVC)    │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
Exposition : Internet → <IP flottante>:80 → Traefik (Ingress) → frontend → /api/ → backend → PostgreSQL
```

---

## Structure du dépôt

```
.
├── .gitignore
├── env.sh                      # variables d'environnement OpenStack + KUBECONFIG
├── terraform/
│   ├── providers.tf            # provider OpenStack
│   ├── variables.tf            # login, image, flavor, keypair, réseaux
│   ├── data.tf                 # data sources : image, flavor, asl-net, subnet, public, keypair
│   ├── security.tf             # Security Group (22, 80, 443)
│   ├── compute.tf              # VM, IP flottante, association Neutron
│   ├── cloud-init.yaml         # utilisateur ubuntu
│   └── outputs.tf              # floating_ip, private_ip, ssh_command, ansible_inventory
├── ansible/
│   ├── ansible.cfg
│   ├── playbook.yml
│   ├── tunnel.sh               # tunnel SSH vers l'API K3s (6443)
│   └── roles/
│       ├── k3s-prereq/         # DNS, /etc/hosts, apt, paquets
│       ├── k3s/                # installation et démarrage de K3s
│       └── kubeconfig/         # récupération du kubeconfig sur DevStack
└── helm/
    ├── postgres/               # StatefulSet + PVC + Service headless + init.sql
    ├── backend/                # Deployment ×2 + ConfigMap (code Python) + Service
    └── frontend/               # Deployment ×2 + ConfigMaps (nginx, HTML) + Service + Ingress
```

Fichiers volontairement **absents** du dépôt (`.gitignore`) : `terraform.tfstate`, `*.tfvars`, `.terraform/`, `kubeconfig`, `*.kubeconfig`, `inventory.ini`.

---

## Prérequis

- Accès à l'hôte DevStack (`stack@devstack`) avec les identifiants `~/devstack/asl-openrc`.
- Socle OpenStack du TD1 déjà en place : projet `asl-project`, réseau `asl-net` / sous-réseau `asl-subnet`, routeur `asl-router`, keypair `asl-key`, image `ubuntu-22.04-asl`.
- Outils installés sur DevStack : Terraform ≥ 1.6, Ansible (+ `sshpass`), Helm 3, kubectl.

Dans chaque nouveau terminal, charger l'environnement :

```bash
source ~/td2/env.sh
```

> Le fichier `env.sh` fait le `source asl-openrc`, supprime `OS_USER_DOMAIN_ID` / `OS_PROJECT_DOMAIN_ID` (qui entrent en conflit avec les variables `*_NAME` et provoquent l'erreur *« exactly one of DomainID or DomainName »*), et positionne `KUBECONFIG`.

---

## Déploiement

### 1. Terraform – infrastructure

```bash
cd terraform
# terraform.tfvars (non versionné) : login = "nawal"
terraform init
terraform plan
terraform apply
terraform output
```

Ressources **créées** (7) : Security Group, 3 règles (22, 80, 443), VM, IP flottante, association IP flottante ↔ port.
Ressources **référencées** par `data` (jamais créées ni détruites) : image, flavor, `asl-net`, `asl-subnet`, réseau `public`, keypair `asl-key`.

### 2. Ansible – configuration de la VM

```bash
terraform output -raw ansible_inventory > ../ansible/inventory.ini
cd ../ansible
ansible -m ping all
ansible-playbook playbook.yml      # 1er passage : changed=4
ansible-playbook playbook.yml      # 2e passage  : changed=0 (idempotence)
```

### 3. Tunnel SSH vers l'API K3s

Le Security Group n'ouvre **pas** le port 6443. `kubectl` et `helm` passent par un tunnel SSH.

```bash
# Terminal 1 : à laisser ouvert
./ansible/tunnel.sh

# Terminal 2 : travail
source ~/td2/env.sh
kubectl get nodes -o wide
```

Le `kubeconfig` produit par Ansible pointe sur l'IP flottante et n'est jamais modifié (pour garder le playbook idempotent). On en fait une **copie** adaptée au tunnel :

```bash
FIP=$(cd terraform && terraform output -raw floating_ip)
sed "s|server: https://$FIP:6443|server: https://127.0.0.1:6443|" \
  ansible/kubeconfig > ansible/tunnel.kubeconfig
chmod 600 ansible/tunnel.kubeconfig
```

### 4. Helm – application 3-tiers

```bash
kubectl create namespace td2
cd helm
helm install postgres ./postgres -n td2 --wait --timeout 5m
helm install backend  ./backend  -n td2 --wait --timeout 5m
helm install frontend ./frontend -n td2 --wait --timeout 5m
```

---

## Validation

```bash
FIP=$(cd terraform && terraform output -raw floating_ip)

helm list -n td2                                   # 3 releases deployed
kubectl -n td2 get pods,svc,ingress                # 5 pods Running
curl -I http://$FIP                                # HTTP/1.1 200 OK
for i in $(seq 1 6); do curl -sI http://$FIP | grep -i '^X-Pod-Name'; done   # alterne entre 2 pods
curl -s http://$FIP/api/items                      # JSON avec 3 items
```

| Contrôle | Résultat attendu |
|---|---|
| `terraform plan` | `No changes` |
| `ansible-playbook playbook.yml` (2ᵉ passage) | `changed=0` |
| `helm list -n td2` | 3 releases `deployed` |
| `curl -I http://<FIP>` | `HTTP/1.1 200 OK` |
| Header `X-Pod-Name` | alterne entre les 2 pods frontend |
| `curl /api/items` | JSON avec `item-alpha`, `item-beta`, `item-gamma` |
| Self-healing | un pod frontend supprimé est recréé en quelques secondes |

---

## Choix techniques

- **`data` vs `resource`** : les ressources partagées du TD1 (réseau, keypair, image…) sont lues avec des `data sources`. Un `terraform destroy` ne peut donc pas les supprimer.
- **Association de l'IP flottante via Neutron** (`openstack_networking_floatingip_associate_v2`), car la ressource Compute équivalente est dépréciée. Le port de la VM est récupéré avec un `data "openstack_networking_port_v2"`.
- **StatefulSet pour PostgreSQL** : identité stable (`postgres-0`), Service headless, `volumeClaimTemplates` (un PVC par réplica). La variable `PGDATA=/var/lib/postgresql/data/pgdata` évite le crash dû au dossier `lost+found` du volume `local-path`.
- **Backend sans image personnalisée** : le code Python est monté depuis un ConfigMap et un `initContainer` installe `pg8000`.
- **Header `X-Pod-Name`** ajouté dans nginx pour prouver le load-balancing avec `curl -I`.
- **Tunnel SSH** plutôt que l'ouverture du port 6443 : principe de moindre privilège réseau, l'API Kubernetes n'est pas exposée sur Internet.
- **Secrets en clair** (`azerty`, `changeme`) : assumé dans ce laboratoire isolé. Ils seraient protégés par Ansible Vault / Sealed Secrets dans un contexte réel (TD3).

---

## Incidents rencontrés et solutions

| Symptôme | Cause | Solution |
|---|---|---|
| `You must provide exactly one of DomainID or DomainName` | `asl-openrc` définit à la fois `OS_*_DOMAIN_ID` et `OS_*_DOMAIN_NAME` | `unset` des variables `_ID` (voir `env.sh`) |
| VM en `ERROR` : `No valid host was found` | Service `nova-compute` à l'état `down` (`ComputeFilter returned 0 hosts` dans le journal du scheduler) | `sudo systemctl restart devstack@n-cpu` |
| SSH vers l'IP flottante en timeout | Route `172.24.4.0/24` absente sur DevStack (`br-ex` sans adresse) | `ip addr add 172.24.4.1/24 dev br-ex`, `ip link set br-ex up`, NAT `iptables` |
| `Permission denied` avec `azerty` | `password` placé dans `users:` de cloud-init (un hash y est attendu) | `chpasswd.users` avec `type: text` |
| `The 'community.general.yaml' callback plugin has been removed` | Plugin supprimé de `community.general` 12 | `stdout_callback = default` + `callback_result_format = yaml` |
| `server: https://https://…:6443:6443` dans le kubeconfig | Mauvais remplacement d'adresse dans le rôle `kubeconfig` | `replace('127.0.0.1', ansible_host)` uniquement |
| `helm install` annulé puis `cannot re-use a name` | `Ctrl+C` pendant `--wait` | `helm uninstall` puis réinstallation sans interruption |
| `grep` du header `X-Pod-Name` sans résultat | Guillemets typographiques `’` copiés depuis le PDF | Apostrophes droites `'` |
| `terraform plan` : `Keypair asl-key not found` | Variables d'environnement d'un autre utilisateur OpenStack | `source ~/td2/env.sh` |

---

## Destruction de l'infrastructure

```bash
source ~/td2/env.sh
helm uninstall frontend backend postgres -n td2
kubectl -n td2 delete pvc --all          # Helm ne supprime pas les PVC
kubectl delete namespace td2

cd terraform
terraform destroy                         # 7 ressources détruites

pkill -f "ssh.*6443:127.0.0.1:6443" || true
unset KUBECONFIG
rm -f ansible/kubeconfig ansible/tunnel.kubeconfig ansible/inventory.ini
```

Après le `destroy`, les ressources partagées (`asl-project`, `asl-user`, `asl-net`, `asl-subnet`, `asl-router`, `public`, `asl-key`, image `ubuntu-22.04-asl`, flavors) subsistent : elles n'appartiennent pas à ce projet Terraform.

---

## Sécurité

- Security Group limité à **22 / 80 / 443**. Pas de 6443 (API K3s), 8472 (VXLAN) ni 10250 (kubelet) : ils ne sont nécessaires qu'en multi-nœuds.
- `terraform.tfstate`, `*.tfvars`, `kubeconfig` et `inventory.ini` ne sont jamais versionnés : le state contient des informations sensibles. En équipe, il serait stocké dans un backend distant chiffré.
- Le tunnel `ssh -L 6443:127.0.0.1:6443` lie le port au seul `127.0.0.1` du poste IaC.
- Mots de passe de laboratoire (`azerty` pour la VM, `changeme` pour PostgreSQL) volontairement en clair, à ne **jamais** reproduire en production.

---

## Suite

Le TD3 passera à une architecture multi-nœuds : registry privé, Ansible Vault, Sealed Secrets et cluster K3s en haute disponibilité.
