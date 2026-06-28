# 🚀 THE ULTIMATE FOG COMPUTING SURVIVAL GUIDE

Questa è la "Bibbia" del progetto. Contiene tutti gli step, gli errori incontrati (e risolti) e le procedure esatte da seguire nel caso in cui tu debba mai **distruggere tutto e ripartire completamente da zero**. 

Se segui questo documento, riporterai in vita l'intero cluster in meno di 15 minuti senza alcun intoppo.

---

## 1. INFRASTRUTTURA BASE E AZURE

*   **Requisito Fondamentale Azure:** La Macchina Virtuale Azure **DEVE** supportare la *Nested Virtualization* (Virtualizzazione Nidificata), altrimenti OpenNebula non potrà creare le macchinette interne. La serie `E4ds_v4` è perfetta.
*   **Sistema Operativo:** Ubuntu 22.04 LTS (Gen 2).
*   **OpenNebula:** Da installare pulito tramite MiniONE. Assicurati che l'interfaccia Sunstone sia accessibile (porta `9869`).

---

## 2. RETE E PROVISIONING DELLE VM

*   **Il problema della rete:** Inizialmente lo script di provisioning si agganciava all'ID della rete in modo statico. Se OpenNebula veniva reinstallato, l'ID cambiava e le macchine non avevano rete.
*   **La soluzione applicata:** Lo script `scripts/provision.sh` ora cerca dinamicamente il nome `fog-network` e si aggancia in automatico.

**Come ricreare le macchine da zero:**
1. Apri il terminale dell'host Azure.
2. Lancia lo script (che distruggerà le vecchie VM e creerà le nuove iniettando i file cloud-init):
   ```bash
   sudo bash ~/fog-project/scripts/provision.sh
   ```
3. Aspetta qualche minuto e controlla gli IP con:
   ```bash
   for vm in $(sudo -u oneadmin onevm list --no-header -l ID | tr -d ' '); do
     NAME=$(sudo -u oneadmin onevm show $vm | grep "^NAME" | awk -F= '{print $2}' | tr -d ' "')
     IP=$(sudo -u oneadmin onevm show $vm | grep ETH0_IP= | head -1 | awk -F'"' '{print $2}')
     echo "$NAME -> $IP"
   done
   ```
4. Testa che tutte le VM si parlino tra loro:
   ```bash
   sudo bash ~/fog-project/scripts/ping-nodes.sh
   ```

---

## 3. IL PROBLEMA DELLE CPU (KUBEADM) E SSH

*   **Il problema `[ERROR NumCPU]`:** Le VM create da MiniONE hanno di default 1 singola vCPU. Kubeadm, che installa Kubernetes, si rifiuta categoricamente di installarsi con meno di 2 CPU e va in crash.
*   **La soluzione applicata:** Bisogna sempre aggiungere il flag `--ignore-preflight-errors=all` (o `NumCPU`) a qualsiasi comando `kubeadm init` o `kubeadm join`. Questo fix è già stato integrato nel file `master-cloud-init.yaml`.
*   **Il problema SSH `Please login as the user ubuntu`:** Le immagini cloud di Ubuntu bloccano per sicurezza il login diretto dell'utente `root`.
*   **La soluzione applicata:** **MAI** fare `ssh root@...`. Fai sempre SSH come utente `ubuntu`, e poi diventa root.
   ```bash
   sudo -u oneadmin ssh ubuntu@<IP_VM>
   # Una volta dentro:
   sudo su
   ```

---

## 4. IL PROBLEMA `LOCALHOST:8080 CONNECTION REFUSED`

*   **Il problema:** Dopo aver installato Kubeadm, lanci `kubectl get nodes` e ti dice che localhost:8080 ha rifiutato la connessione.
*   **Il motivo:** Questo significa che `kubectl` non sa dove si trova il cluster, perché ti sei dimenticato di copiargli il file di configurazione generato da Kubeadm.
*   **La soluzione (da lanciare sul Master):**
   ```bash
   sudo su
   mkdir -p /root/.kube
   cp -f /etc/kubernetes/admin.conf /root/.kube/config

   mkdir -p /home/ubuntu/.kube
   cp -f /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
   chown -R ubuntu:ubuntu /home/ubuntu/.kube

   export KUBECONFIG=/etc/kubernetes/admin.conf
   ```

---

## 5. IL PROBLEMA DEI NODI IN STATO `NOT READY`

*   **Il problema:** Fai `kubectl get nodes` e tutti i nodi rimangono appesi in stato `NotReady` all'infinito.
*   **Il motivo:** Kubernetes ha bisogno di un plugin di rete CNI per far comunicare i Pod, altrimenti tiene i nodi disattivati per sicurezza.
*   **La soluzione:** Installa Flannel dal nodo Master:
   ```bash
   kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
   ```
   *(Dopo 30 secondi diventeranno tutti `Ready`)*.

---

## 6. GVISOR E I PERMESSI NEGATI

*   **Il problema:** Lanciare lo script `setup-gvisor.sh` restituiva "Permission Denied" per l'utente `oneadmin` oppure falliva l'accesso SSH.
*   **La soluzione applicata:** Lo script ora si collega via SSH come `ubuntu` e lancia `sudo bash -s`. E per aggirare i permessi delle cartelle locali sull'host Azure, basta copiare lo script in `/tmp`.
*   **Procedura d'installazione gVisor:**
   1. Dall'host Azure:
      ```bash
      cp ~/fog-project/scripts/setup-gvisor.sh /tmp/
      sudo -u oneadmin bash /tmp/setup-gvisor.sh 172.16.100.3 "edge-node-1"
      sudo -u oneadmin bash /tmp/setup-gvisor.sh 172.16.100.4 "edge-node-2"
      sudo -u oneadmin bash /tmp/setup-gvisor.sh 172.16.100.5 "edge-node-3"
      ```
   2. Dal nodo Master (per registrare gVisor su Kubernetes):
      ```bash
      cat <<EOF | kubectl apply -f -
      apiVersion: node.k8s.io/v1
      kind: RuntimeClass
      metadata:
        name: gvisor
      handler: runsc
      EOF
      ```

---

## 7. FALCO, I POD IN CRASHLOOP E IL PASS-THROUGH

*   **Il problema:** Falco parte correttamente sul nodo Master, ma va in `CrashLoopBackOff` su tutti i nodi Worker.
*   **Il motivo:** Falco utilizza sensori eBPF o moduli Kernel molto a basso livello per scansionare le chiamate di sistema alla ricerca di virus/intrusioni. I worker, essendo macchine virtuali su OpenNebula, nascondevano le funzionalità hardware reali della CPU al sistema operativo guest.
*   **La soluzione risolutiva:** Devi **abilitare il CPU Pass-Through** nel template OpenNebula dei Worker. Questo espone l'architettura esatta del processore fisico al kernel virtuale, permettendo al modulo eBPF di Falco di compilarsi e agganciarsi correttamente al Kernel senza andare in crash!

---

## 8. SETUP E TESTING DI FALCO

*   **Installazione via Helm:** Falco si installa nel cluster tramite Helm, forzando l'uso del driver eBPF moderno (che è il più compatibile con i kernel recenti se il CPU Pass-Through è abilitato).
   ```bash
   # Scarica e installa Helm
   curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
   chmod +x get_helm.sh
   ./get_helm.sh 
   
   # Aggiungi la repo di Falco e installa
   helm repo add falcosecurity https://falcosecurity.github.io/charts
   helm repo update
   helm install falco falcosecurity/falco \
     --namespace falco \
     --create-namespace \
     --set driver.kind=modern_ebpf
   ```
*   **Test di Sicurezza in Tempo Reale:** Per verificare che Falco stia effettivamente monitorando il cluster:
   1. Crea un pod malevolo/di test:
      ```bash
      kubectl run falco-tester --image=nginx
      ```
   2. Entra nel pod e simula un attacco (es. aprendo una shell e sbirciando `/etc/shadow`):
      ```bash
      kubectl exec -it falco-tester -- /bin/bash
      cat /etc/shadow
      exit
      ```
   3. Controlla i log di allerta di Falco (sul master):
      ```bash
      kubectl logs -l app.kubernetes.io/name=falco -n falco -c falco | grep -i "Notice"
      ```
      Se compare il messaggio `Notice A shell was spawned in a container...` significa che Falco ha intercettato con successo l'intrusione a livello kernel!
