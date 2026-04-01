import os
import enum
import platform
import pathlib
import argparse
import shutil
import subprocess
import tempfile
import getpass
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

log = logging.getLogger(__file__)

class ProvisionVMCommand:
    def handle(self, args: argparse.Namespace):
        vm_base_image = _download_vm_image(distro=args.distro)
        disk = _create_vm_disk(image=vm_base_image, vm_name=args.name)
        cloud_init = _create_cloud_init(vm_name=args.name)
        share_dir = _setup_virtiofs_share(args.name)
        _create_vm(vm_name=args.name,
                   memory=args.memory,
                   cpus=args.vcpus,
                   disk=disk,
                   distro=args.distro,
                   cloud_init=cloud_init,
                   host_mount=share_dir)

    def define_args(self, p: argparse.ArgumentParser):
        p.add_argument('name', type=str, help='VM name')
        p.add_argument('--memory',
                       type=int,
                       default=8<<10,
                       help='memory in MiB')
        p.add_argument('--vcpus',
                       type=int,
                       default=4,
                       help='VCPUs to assign to the VM')
        p.add_argument('--distro',
                       type=Distro,
                       default=Distro.DEBIAN_TRIXIE,
                       choices=list(Distro))


class Distro(enum.StrEnum):
    DEBIAN_TRIXIE = 'debian' # 13
    UBUNTU_NOBLE = 'ubuntu'  # 24.04

    @property
    def libvirt_os_string(self) -> str:
        match self:
            case Distro.DEBIAN_TRIXIE:
                return 'debian13'
            case Distro.UBUNTU_NOBLE:
                return 'ubuntu24.04'

    @property
    def image_url(self) -> tuple[str, str]:
        match self:
            case Distro.DEBIAN_TRIXIE:
                image_name = f'debian-13-generic-{_get_processor_architecture()}.qcow2'
                return (
                    image_name,
                    f'https://cloud.debian.org/images/cloud/trixie/latest/{image_name}',
                )

            case Distro.UBUNTU_NOBLE:
                image_name = f'noble-server-cloudimg-{_get_processor_architecture()}.img'
                return (
                    image_name,
                    f'https://cloud-images.ubuntu.com/noble/current/{image_name}',
                )

def _get_data_dir() -> pathlib.Path:
    xdg_home = pathlib.Path(
        os.environ.get(
            'XDG_DATA_HOME',
            pathlib.Path.home() / '.local' / 'share'))

    data_dir = xdg_home / 'devenv_provisiner'
    if not data_dir.exists():
        data_dir.mkdir(mode=0o755, parents=True)

    return data_dir

def _get_processor_architecture():
    machine = platform.machine().lower()
    if machine in ['amd64', 'x86_64']:
        return 'amd64'
    elif machine in ['arm64', 'aarch64']:
        return 'arm64'

    raise Exception(f'unsupported platform "{machine}"')

def _download_vm_image(distro: Distro):
    curl = shutil.which('curl')
    if not curl:
        raise Exception('curl not found')

    out_dir = _get_data_dir()
    image_name, image_url = distro.image_url

    full_path = out_dir / image_name
    if full_path.exists():
        return full_path

    log.info(f'downloading distro image {image_name=}\n\n\n')

    subprocess.run(
        (curl, '--retry', '3', '-SfL', image_url, '-o', image_name),
        cwd=out_dir,
        check=True,
    )

    return full_path

def _create_vm_disk(image: pathlib.Path,
                    vm_name: str,
                    size_gb: int = 40) -> pathlib.Path:
    qemu_img = shutil.which('qemu-img')
    if not qemu_img:
        raise Exception('qemu-img not found')

    disks_dir = _get_data_dir() / 'disks'
    if not disks_dir.exists():
        disks_dir.mkdir()

    disk_path = disks_dir / f'{vm_name}.qcow2'
    subprocess.run(
        (qemu_img, 'create',
         '-f', 'qcow2', '-b', str(image),
         '-F', 'qcow2', str(disk_path),
         f'{size_gb}G'),
        check=True,
    )

    return disk_path

def _get_all_vm_names():
    virsh = shutil.which('virsh')
    if not virsh:
        raise Exception('virsh not found')

    proc = subprocess.run((virsh, '--connect', 'qemu:///system', 'list', '--all', '--name'),
                          stdout=subprocess.PIPE,
                          check=True,
                          text=True)

    return [vm.strip() for vm in proc.stdout.split('\n')
        if len(vm.strip()) > 0]

def _create_cloud_init(vm_name: str):
    starting_ip = 100
    vm_count = len(_get_all_vm_names())

    # CZ.NIC DNS
    nameservers = ['193.17.47.1', '185.43.135.1']

    with tempfile.TemporaryDirectory(prefix=f'{vm_name}-cloudinit', delete=False) as cinit_root:
        root = pathlib.Path(cinit_root)
        os.chmod(root, 0o755)

        with open(root / 'network-config', 'x') as networkdata:
            networkdata.write(f"""\
version: 2
ethernets:
  ens:
    match:
      name: "en*"
    dhcp4: no
    addresses: [192.168.122.{starting_ip + vm_count}/24]
    gateway4: 192.168.122.1
    nameservers:
      addresses: [{",".join(nameservers)}]
""")

        with open(root / 'meta-data', 'x') as metadata:
            metadata.write(f"""\
instance-id: {vm_name}
local-hostname: {vm_name}
""")

        with open(root / 'user-data', 'x') as userdata:
            user = getpass.getuser()

            ssh_key: str
            with open(os.path.join(os.environ['HOME'], '.ssh', 'id_ed25519.pub'), 'r') as key_file:
                ssh_key = key_file.read()

            userdata.write(f"""\
#cloud-config
hostname: {vm_name}
chpasswd:
  list: |
     {user}:123456
  expire: False
users:
  - name: {user}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - {ssh_key.strip()}
manage_etc_hosts: true
ssh_pwauth: false
package_update: true
package_upgrade: true
packages:
  - python3
  - python3-apt
  - curl
  - ca-certificates
mounts:
  - [ shared_data, /home/{user}/workspace, virtiofs, "defaults", "0", "0" ]
runcmd:
  - mkdir -p /home/{user}/workspace
  - chown -R {user}:{user} /home/{user}
  - mount -a
""")

        for file_name in ['user-data', 'meta-data', 'network-config']:
            os.chmod(root / file_name, 0o644)

        return root

def _setup_virtiofs_share(vm_name):
    """
    TODO: cleanup
    Sets up a private VirtioFS share in ~/.local/share/devenv_provisioner/
    Returns the absolute path to the share.
    """
    user_home = pathlib.Path.home()
    base_dir = _get_data_dir() / 'virtiofs'
    share_path = base_dir / vm_name

    if share_path.exists():
        active_vms = _get_all_vm_names()
        for folder in base_dir.iterdir():
            if folder.is_dir() and folder.name not in active_vms:
                print(f"Cleaning up orphaned share: {folder}")
                try:
                    shutil.rmtree(folder)
                except OSError as e:
                    print(f"Error deleting {folder}: {e}")

    if not share_path.exists():
        print(f'Creating share directory: {share_path}')
        share_path.mkdir(parents=True, exist_ok=True)

    # 3. Handle the 'Pass-through' permissions
    # libvirt-qemu needs '+x' on every parent to reach the destination
    # We use sudo setfacl to avoid changing your actual folder permissions (drwx------)
    parents_to_check = [user_home, user_home / '.local', user_home / '.local/share']

    print('Ensuring libvirt-qemu can traverse to the share...')
    for parent in parents_to_check:
        # Check if ACL is already set to avoid redundant sudo calls
        acl_check = subprocess.run(['getfacl', str(parent)], capture_output=True, text=True)
        if 'user:libvirt-qemu:--x' not in acl_check.stdout:
            subprocess.run(['sudo', 'setfacl', '-m', 'u:libvirt-qemu:x', str(parent)], check=True)

    # 4. Grant full Access to the final VM-specific folder
    acl_check_final = subprocess.run(['getfacl', str(share_path)], capture_output=True, text=True)
    if 'user:libvirt-qemu:rwx' not in acl_check_final.stdout:
        print(f'Granting VM rwx access to {share_path}')
        # -m: modify, -d: default (for future files)
        subprocess.run(['sudo', 'setfacl', '-m', 'u:libvirt-qemu:rwx', str(share_path)], check=True)
        subprocess.run(['sudo', 'setfacl', '-d', '-m', 'u:libvirt-qemu:rwx', str(share_path)], check=True)
    else:
        print('Permissions already correctly configured.')

    return share_path

def _create_vm(vm_name: str,
               memory: int,
               cpus: int,
               disk: pathlib.Path,
               distro: Distro,
               cloud_init: pathlib.Path,
               host_mount: pathlib.Path):

    userdata = cloud_init / 'user-data'
    metadata = cloud_init / 'meta-data'
    networkdata = cloud_init / 'network-config'

    assert host_mount.exists()
    assert userdata.exists()
    assert metadata.exists()
    assert networkdata.exists()

    virt_install = shutil.which('virt-install')
    if not virt_install:
        raise Exception('virt-install not found')

    cmd = (
        virt_install,
        '--connect', 'qemu:///system',
        '--virt-type', 'kvm',
        '--name', vm_name,
        '--memory', str(memory),
        '--vcpus', str(cpus),
        '--os-variant', distro.libvirt_os_string,
        '--import',
        '--disk', f'path={str(disk.absolute())},format=qcow2',
        '--network', 'network=default,model=virtio',
        '--graphics', 'vnc',
        '--noautoconsole',
        '--cloud-init', f'user-data={userdata},meta-data={metadata},network-config={networkdata}',
        '--filesystem', f'{str(host_mount.absolute())},shared_data,type=mount,driver.type=virtiofs',
        '--memorybacking', 'access.mode=shared',
    )

    subprocess.run(cmd, check=True)
