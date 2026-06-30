# ☁️ Azure VM Migration Guide

This guide details the exact steps to migrate the DUKA OpenNebula host to a new Azure subscription or resource group to utilize new billing credits, without losing any Kubernetes or OpenNebula state.

---

## Phase 1: Safe Shutdown & Snapshot

1. **Shutdown from within Linux first (Safest):**
   You should always shut down nested virtualization gracefully. Connect via SSH to the Azure VM (`duka@<AZURE_IP>`) and run:
   
   ```bash
   sudo shutdown now
   ```
   *(This ensures OpenNebula safely shuts down the inner KVM VMs without corrupting their virtual disks).*

2. **Deallocate in Azure:**
   Go to the Azure Portal ➔ Virtual Machines. Wait for the status to say "Stopped", then click the **Stop (Deallocate)** button to ensure you are no longer being billed for compute.

3. **Create the Snapshot:**
   * Click on your VM in the Azure Portal.
   * Go to **Disks** on the left-hand menu.
   * Click on the OS Disk (it usually has the VM name followed by some random string).
   * Click **Create Snapshot** at the top of the page.
   * Choose "Standard HDD" (it's cheaper and perfectly fine for creating snapshots).

---

## Phase 2: Migration

* **If staying in the same Azure Account (different subscription):**
  Navigate to the newly created Snapshot ➔ Click "Move" at the top ➔ Select the new Subscription.
* **If moving to a completely different Azure Account:**
  Navigate to the Snapshot ➔ Click "Snapshot Export" ➔ Generate a SAS URL. Use Azure Storage Explorer to copy the underlying VHD file to the new Azure account.

---

## Phase 3: Resurrection

1. In the new subscription/account, go to the search bar and type **Disks** ➔ **Create**.
2. Select **Source Type: Snapshot** (or Storage Blob if you copied the VHD) and choose your snapshot.
3. Once the new Managed Disk is created, click on it and select **Create VM** from the top menu.
4. Configure the VM exactly like the old one (Size `E4ds_v4` or similar is required since nested virtualization requires hypervisor-enabled instances).
5. Ensure the new Network Security Group (NSG) allows port `22` (SSH) and `30080` (DUKA Gateway NodePort).

---

## Phase 4: Re-linking the Network

Once the new VM boots, its internal architecture (OpenNebula, Kubernetes, Edge IPs) is 100% untouched. The only thing that changed is the Azure Public IP address.

1. Connect via SSH using the NEW Public IP: `ssh duka@<NEW_AZURE_IP>`
2. Run your persistence script to re-establish the edge routing:
   ```bash
   ./start_duka.sh
   ```
3. The cluster is now fully migrated, securely funded, and operational!
