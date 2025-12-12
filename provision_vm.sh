#!/usr/bin/env bash
set -euo pipefail

# === Defaults updated per your request ===
VM_FOLDER="./vm_disks"
BASE_IMAGE="../images/debian-13-generic-amd64.qcow2"

MEMORY=8192
CPUS=4
DISK_SIZE=32
RUN_ANSIBLE=0
SSH_KEY_FILE=""
SSH_PRIVATE_KEY_FILE=""
VM_NAME=""
IP=""

usage() {
  cat <<EOF
Usage: $0 -n <vmname> -k <ssh-public-key> -p <private-ssh-key> -i <ip-octet> [-m <memory MiB>] [-c <cpus>] [-d <disk GB>] [-a]
  -n  VM name (required)
  -k  SSH public key file (required)
  -p  SSH private key file (required)
  -i  last octet of the static IP (required)
  -m  Memory in MiB (default ${MEMORY})
  -c  vCPUs (default ${CPUS})
  -d  Disk size in GB (default ${DISK_SIZE})
  -a  Run ansible after boot (optional)
EOF
  exit 1
}

cleanup() {
  [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

while getopts "i:p:n:k:m:c:d:a" opt; do
  case $opt in
    n) VM_NAME="$OPTARG" ;;
    k) SSH_KEY_FILE="$OPTARG" ;;
    m) MEMORY="$OPTARG" ;;
    c) CPUS="$OPTARG" ;;
    d) DISK_SIZE="$OPTARG" ;;
    a) RUN_ANSIBLE=1 ;;
    p) SSH_PRIVATE_KEY_FILE="$OPTARG" ;;
    i) IP="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$VM_NAME" || -z "$SSH_KEY_FILE" || -z "$SSH_PRIVATE_KEY_FILE" || -z "$IP" ]] && usage
[[ ! -f "$SSH_KEY_FILE" ]] && { echo "SSH public key not found: $SSH_KEY_FILE" >&2; exit 2; }

SSH_KEY=$(<"$SSH_KEY_FILE")
DISK_PATH="${VM_FOLDER}/${VM_NAME}.qcow2"

echo "==> Creating VM disk (backed by ${BASE_IMAGE})..."
mkdir -p "$VM_FOLDER"
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK_SIZE}G"

TMPDIR="$(mktemp -d /tmp/${VM_NAME}-cloudinit.XXXX)"
USERDATA="${TMPDIR}/user-data"
METADATA="${TMPDIR}/meta-data"
NETWORKDATA="${TMPDIR}/network-config.yaml"

STATIC_IP="192.168.122.${IP}"
echo "Static IP: $STATIC_IP"

cat > "$NETWORKDATA" <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: no
    addresses: [${STATIC_IP}/24]
    gateway4: 192.168.122.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

SSH_PRIVATE_KEY=$(base64 -w0 "$SSH_PRIVATE_KEY_FILE")

cat > "$USERDATA" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_KEY}

ssh_pwauth: false
package_update: true
package_upgrade: true

write_files:
  - path: /tmp/id_ed25519
    permissions: '0600'
    encoding: b64
    content: "${SSH_PRIVATE_KEY}"

runcmd:
  - mkdir -p /home/${USER}/.ssh
  - mv /tmp/id_ed25519 /home/${USER}/.ssh/id_ed25519
  - chown ${USER}:${USER} /home/${USER}/.ssh/id_ed25519
  - ssh-keyscan -t rsa github.com >> /home/${USER}/.ssh/known_hosts

  - chmod 700 /home/${USER}/.ssh
  - chmod 600 /home/${USER}/.ssh/id_ed25519
  - chmod 644 /home/${USER}/.ssh/known_hosts

  - apt-get update
  - apt-get upgrade -y
  - apt-get install --no-install-recommends -y python3 ansible git
EOF

cat > "$METADATA" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

echo "==> Using cloud-init:"
ls -l "$USERDATA" "$METADATA"

echo "==> Running virt-install..."
virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --vcpus "$CPUS" \
  --disk "path=${DISK_PATH},format=qcow2" \
  --osinfo debian13 \
  --import \
  --graphics vnc \
  --network network=default,model=virtio \
  --noautoconsole \
  --cloud-init "user-data=${USERDATA},meta-data=${METADATA},network-config=${NETWORKDATA}"

echo "==> VM ${VM_NAME} created successfully!"

