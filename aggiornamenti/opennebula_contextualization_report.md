# 🐛 DUKA Project: OpenNebula Contextualization & Bridge Race Condition

This document details a critical race condition discovered between the OpenNebula hypervisor lifecycle and ephemeral Linux networking. It documents the symptoms, the advanced hypervisor-level debugging techniques used to diagnose it, and the declarative Infrastructure-as-Code fix.

---

## 📌 1. The Context

Our Edge/Fog topology relies on custom Layer 3 isolated networks (`10.1.1.0/24`, etc.). To facilitate these networks, custom Linux bridges (`br-edge-1`, `br-edge-2`, `br-edge-3`) were created on the OpenNebula host to act as gateways between the K8s Master and the Edge Workers.

Originally, these bridges were created manually using terminal commands (`ip link add type bridge`). This meant their existence was ephemeral—they lived in the RAM of the Linux kernel but were not written to disk.

## 💥 2. The Cascade Failure

When the underlying Azure VM was deallocated and reallocated to simulate an infrastructure migration, a severe cascade failure occurred:

1. **The Amnesia:** The Linux kernel rebooted and completely wiped the ephemeral bridges from existence.
2. **The Race Condition:** The OpenNebula daemon (`oned`) is configured to auto-start on boot. It immediately woke up the worker VMs.
3. **The Contextualization Crash:** As the worker VMs booted, OpenNebula attempted to plug their virtual network cables into the bridges. Because the bridges didn't exist, the attachment failed. Inside the worker VMs, the Ubuntu operating system detected a missing carrier. Consequently, `systemd-networkd` inside the guest completely crashed the network stack, leaving the interfaces in a `STATE DOWN` with no IP assigned.
4. **The Ghost State:** We manually recreated the bridges on the host and used `ip link set up` to force the virtual cables on. However, because the guest OS had already crashed its network stack during the initial boot, it remained completely deaf. All ARP requests and Pings resulted in `Destination Host Unreachable`.

## 🕵️ 3. Advanced Debugging via QEMU Guest Agent

Because the guest network was completely down, SSH access was impossible. The OpenNebula template also lacked a virtual serial console, meaning we were locked out of our own VMs.

To diagnose the issue without destroying the VMs, we utilized the **QEMU Guest Agent** backdoor from the hypervisor root. We injected commands directly into the VM's memory to retrieve its network state:

```bash
# Inject 'ip a' execution directly into the guest VM via virsh
sudo virsh qemu-agent-command one-8 '{"execute": "guest-exec", "arguments": { "path": "/bin/ip", "arg": [ "a" ], "capture-output": true } }'

# Retrieve and decode the Base64 output from the guest agent
```

**The Decoded Output:**
```text
2: enp3s0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
    link/ether 02:00:0a:01:01:64 brd ff:ff:ff:ff:ff:ff
```
This scientifically proved the diagnosis: the guest OS network interface was completely disabled and lacked the `10.1.1.100` Contextualization IP.

## 🔧 4. The Permanent Fix

To recover the current state, we executed a full `undeploy` and `resume` via OpenNebula. This safely shut down the VMs and forced the hypervisor to completely rebuild the `libvirt` XML from scratch, properly re-attaching the virtual cables to the new bridges.

To prevent this from ever happening during future migrations or reboots, we shifted to a declarative **Infrastructure-as-Code (IaC)** approach. 

We hardcoded the edge bridges into the Ubuntu kernel's core routing file:
**`/etc/netplan/02-edge-bridges.yaml`**
```yaml
network:
  version: 2
  bridges:
    br-edge-1:
      addresses: [10.1.1.1/24]
    br-edge-2:
      addresses: [10.1.2.1/24]
    br-edge-3:
      addresses: [10.1.3.1/24]
```

### Architectural Result
Now, when the Azure VM reboots, the Linux kernel reads `netplan` and creates the bridges within the first 3 seconds of booting. When OpenNebula wakes up 30 seconds later, the infrastructure is already waiting for it. The VMs boot flawlessly, discover the bridges, and initialize their networking with 0% packet loss.
