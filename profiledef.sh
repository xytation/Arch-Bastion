#!/usr/bin/env bash
# =============================================================================
# profiledef.sh — archiso profile definition for Arch Bastion ISO
# Place this in: bastion-iso/profiledef.sh
# =============================================================================

iso_name="arch-bastion"
iso_label="ARCH_BASTION_$(date +%Y%m)"
iso_publisher="Bastion Project"
iso_application="Arch Linux Hardened Bastion"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito'
           'uefi-ia32.grub.esp' 'uefi-x64.systemd-boot.esp'
           'uefi-x64.systemd-boot.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/bastion-bootstrap.sh"]="0:0:755"
  ["/usr/local/bin/bastion-install.sh"]="0:0:755"
  ["/etc/ssh/sshd_config"]="0:0:600"
)
