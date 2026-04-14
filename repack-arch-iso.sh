#!/usr/bin/env bash

# // SPDX-License-Identifier: GPL-2.0+

#  (C) Copyright 2026
#  julianbs789 <test789787@gmail.com>

set -e

if [ "$#" -ne 2 ] && [ "$#" -ne 1 ]; then
    echo "usage:" 1>&2
    echo "$0 <input.iso> [<output.iso>]" 1>&2
    exit 1
fi

readonly SSH_ID_FILE="id_ed25519.priv"
readonly SSH_PORT="2222"
readonly INPUT_ISO="$1"
OUTPUT_ISO="repacked.iso"
readonly WPORT="3333"
readonly ISONAME="CUSTOMISO"

if [ "$#" -eq 2 ]; then
    OUTPUT_ISO="$2"
fi

if [ -f "$OUTPUT_ISO" ]; then
    echo "the output '$OUTPUT_ISO' is already exisiting" 1>&2
    exit 1
fi

generate_ssh_id() {
    if ! [ -f "$SSH_ID_FILE" ]; then
        ssh-keygen -t ed25519 -a 100 -o -f "$SSH_ID_FILE"
    else
        echo "SSH id file already existing"
    fi

    if ! [ -f "$SSH_ID_FILE.pub" ]; then
        echo "pubkey for $SSH_ID_FILE missing!" 1>&2
        exit 1
    fi

    PUBKEY="$(cat $SSH_ID_FILE.pub)"
}

generate_user_data_template() {
    cat > cloudinit/user-data  << EOF
#cloud-config


runcmd:
  - [ nc, -N, 10.0.2.2, $WPORT ]

users:
  - name: arch
    ssh_authorized_keys:
     - $PUBKEY
    sudo: "ALL=(ALL) NOPASSWD:ALL"
EOF
}

generate_seed_img() {
    cd cloudinit
    genisoimage -output seed.img \
        -volid cidata -rational-rock -joliet \
        user-data vendor-data meta-data network-config
    cd ..
}

generate_ssh_id
generate_user_data_template
generate_seed_img

qemu-system-x86_64 \
    -enable-kvm -smp 4 -m 6000 \
    -boot d  \
    -cdrom "$INPUT_ISO" \
    -drive file=cloudinit/seed.img,media=cdrom \
    -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 &

echo "Waiting for the VM to respond"
nc -lp "$WPORT"
echo "VM is ready"

# we use expansions in the here document as a feature
#shellcheck disable=SC2087
ssh arch@localhost -p 2222 -i "$SSH_ID_FILE"  \
    -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -oPasswordAuthentication=no sh << EOF

set -ex
sudo pacman --noconfirm -Sy mtools dosfstools xorriso
sudo mount -oremount,size=5000000000,nr_inodes=0 /tmp
cd /tmp
sudo unsquashfs -d out /run/archiso/bootmnt/arch/x86_64/airootfs.sfs
sudo touch out/testing.txt
sudo mksquashfs out new.sfs -comp xz -b 1048576 
sudo rm -rf out/
cp -r /run/archiso/bootmnt .
dd if=/dev/zero of=efiboot-repack.img bs=1M count=250
mkfs.vfat efiboot-repack.img 
mmd -i efiboot-repack.img EFI loader boot arch 
mcopy -i efiboot-repack.img -s bootmnt/arch/boot/ ::/arch/
mcopy -i efiboot-repack.img -s bootmnt/EFI/BOOT/ ::/EFI/
mcopy -i efiboot-repack.img -s bootmnt/loader/ ::/
mcopy -i efiboot-repack.img -s bootmnt/boot/memtest86+/ ::/boot/
mcopy -i efiboot-repack.img -s bootmnt/shellia32.efi ::/
mcopy -i efiboot-repack.img -s bootmnt/shellx64.efi ::/
chmod u+w bootmnt/
mv efiboot-repack.img bootmnt/
sudo mv new.sfs bootmnt/arch/x86_64/airootfs.sfs

rm -rf out

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid $ISONAME \
    -eltorito-boot boot/syslinux/isolinux.bin \
    -eltorito-catalog boot/syslinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr bootmnt/boot/syslinux/isohdpfx.bin \
    -eltorito-alt-boot \
    -e efiboot-repack.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output new.iso  bootmnt/

EOF

scp -P 2222 -i "$SSH_ID_FILE"  \
    -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -oPasswordAuthentication=no arch@localhost:/tmp/new.iso "$OUTPUT_ISO"
