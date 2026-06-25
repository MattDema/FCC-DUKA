# Cheat Sheet: Gestione del Cluster Kubernetes su OpenNebula

Questo file contiene tutti i comandi utili e i passaggi manuali che abbiamo affrontato, così hai un riferimento rapido per la prossima volta.

## 1. Testare la connettività (Ping test)
Per vedere subito se le VM hanno rete e si parlano, lancia lo script dedicato (dall'host Azure):
```bash
sudo bash ~/fog-project/scripts/ping-nodes.sh
```

---

## 2. Fix manuale dell'installazione Master (se si blocca per 1 vCPU)
Se `cloud-init` fallisce il setup di Kubernetes perché la VM ha 1 sola vCPU, entra nel master (`sudo -u oneadmin ssh root@<IP_MASTER>`) e lancia:

```bash
# Pulisce l'installazione fallita
kubeadm reset -f

# Lancia l'installazione ignorando tutti gli errori preflight
kubeadm init --pod-network-cidr=10.244.0.0/16 --token-ttl=0 --ignore-preflight-errors=all

# Configura il client kubectl
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config

# Installa il layer di rete dei pod (Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

---

## 3. Aggiungere i Worker al Cluster
Per unire i nodi worker al cluster appena creato, servono due passaggi:

**Dal Master (recupera il token di join):**
```bash
kubeadm token create --print-join-command
```

**Da ciascun Worker (esegui l'unione):**
Fai SSH in ogni worker (`sudo -u oneadmin ssh root@<IP_WORKER>`), incolla il comando precedente e aggiungi il flag per le CPU alla fine. Esempio:
```bash
kubeadm join <IP_MASTER>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH> --ignore-preflight-errors=all
```

---

## 4. Verifica dello stato generale (dal Master)
```bash
# Verifica lo stato di avanzamento di cloud-init
cloud-init status --wait

# Controlla che tutti i nodi siano uniti e in stato Ready
kubectl get nodes
```
