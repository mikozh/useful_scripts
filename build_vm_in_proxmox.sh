#!/usr/bin/env bash
set -euo pipefail
# Shell script to build VM in proxmox
# Usage:
#   ./build-proxmox-vm.sh AltaiOS-24.04.4_13Mar_01.iso
#
# Optional env override:
#   VMID=103 ./build-proxmox-vm.sh AltaiOS-24.04.4_13Mar_01.iso

VMID="${VMID:-103}"
ISO_FILE="${1:-}"
ISO_DIR="/var/lib/vz/template/iso"

if [[ -z "${ISO_FILE}" ]]; then
  echo "Usage: $0 <iso-file-name>"
  exit 1
fi

if [[ ! -f "${ISO_DIR}/${ISO_FILE}" ]]; then
  echo "Error: ISO not found: ${ISO_DIR}/${ISO_FILE}"
  exit 1
fi

# Convert ISO filename into a Proxmox-safe DNS-style VM name
sanitize_vm_name() {
  local raw="$1"
  local name
  local result=""
  local label

  # remove .iso suffix if present
  name="${raw%.iso}"
  [[ "$name" == "$raw" ]] && name="${raw%.*}"

  # lowercase
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  # replace invalid chars (including _) with hyphen
  name="$(printf '%s' "$name" | sed -E 's/[^a-z0-9.-]+/-/g')"

  # collapse repeated hyphens and dots
  name="$(printf '%s' "$name" | sed -E 's/-+/-/g; s/\.+/./g')"

  # trim leading/trailing dots
  name="$(printf '%s' "$name" | sed -E 's/^\.//; s/\.$//')"

  # sanitize each dot-separated label:
  # no leading/trailing hyphens, no empty labels
  IFS='.' read -r -a parts <<< "$name"
  for label in "${parts[@]}"; do
    label="$(printf '%s' "$label" | sed -E 's/^-+//; s/-+$//')"
    [[ -z "$label" ]] && continue
    if [[ -n "$result" ]]; then
      result="${result}.${label}"
    else
      result="${label}"
    fi
  done

  # fallback if everything got stripped
  if [[ -z "$result" ]]; then
    result="vm-${VMID}"
  fi

  printf '%s\n' "$result"
}

VMNAME="$(sanitize_vm_name "$ISO_FILE")"
ISO_STORAGE_REF="local:iso/${ISO_FILE}"

if qm status "${VMID}" >/dev/null 2>&1; then
  echo "Error: VM ${VMID} already exists."
  exit 1
fi

echo "ISO file:    ${ISO_FILE}"
echo "VM name:     ${VMNAME}"
echo "Creating VM ${VMID}..."

qm create "${VMID}" \
  --name "${VMNAME}" \
  --memory 16384 \
  --balloon 0 \
  --cores 4 \
  --sockets 1 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --numa 0

echo "Adding disk..."
qm set "${VMID}" --scsi0 local-lvm:256,iothread=1

echo "Attaching ISO..."
qm set "${VMID}" --ide2 "${ISO_STORAGE_REF}",media=cdrom

echo "Setting boot order..."
qm set "${VMID}" --boot order=scsi0\;ide2\;net0

echo "Adding PCI passthrough device..."
qm set "${VMID}" --hostpci0 0000:01:00,pcie=1

echo "Starting VM..."
qm start "${VMID}"

echo "Done. VM ${VMID} (${VMNAME}) has been created and started."
