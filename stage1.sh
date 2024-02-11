#!/bin/bash

cyan=14
blue=12
green=10
red=9
yellow=11
white=15
pink=13

bolden() {
	tput bold
	echo -e "$1"
	tput sgr0
}

notify() {
	tput bold
	tput setaf "$blue"
	echo ' -> ' | tr -d '\n'
	tput setaf "$white"
	echo "$1"
	tput sgr0
}

success() {
	tput bold
	echo '[ ' | tr -d '\n'
	tput setaf "$green"
	echo '  OK  ' | tr -d '\n'
	tput setaf "$white"
	echo " ] $1"
	tput sgr0
}

if [[ ! -d '/sys/firmware/efi' ]]; then
	echo 'error: Cannot run installation script because this device does not support UEFI. Aborting installation..'
	exit 1
fi
success 'Device supports UEFI'

if [[ ! -f './dotfiles.tar.gz' ]]; then
	echo 'error: unable to find './dotfiles.tar.gz'. Aborting installation..'
	exit 1
fi
success 'Found ./dotfiles.tar.gz'

if [[ ! -f './.git-credentials' ]]; then
	echo 'error: unable to find './.git-credentials'. Aborting installation..'
	exit 1
fi
success 'Found ./.git-credentials'

read -p "Before continuing, this installation script assumes you've created your /efi and / partitions.\
It also assumes that the machine has functional internet access, and that secure boot is disabled \
(you can re-enable it after the installation). If you've done all of these things, \
type 'y' to continue with the installation [y/n] " confirm_install

if [[ "$confirm_install" != 'y' ]]; then
	echo 'Aborting installation..'
	exit 1
fi

read -p 'Path to your EFI partition: ' efi

if [[ ! -b "$efi" ]]; then
	echo "error: '$efi' is not a block device. Aborting installation"
	exit 1
fi

read -p 'Path to your partition you want to install and encrypt Arch Linux on: ' enc

if [[ ! -b "$enc" ]]; then
	echo "error: '$enc' is not a block device. Aborting installation"
	exit 1
fi

efi_fs_type=$(blkid "$efi" | awk '{print $4}')
if [[ "$efi_fs_type" != 'TYPE="vfat"' ]]; then
	notify "Setting $efi as a FAT32 partition.."
	mkfs.fat -F32 "$efi"
fi

root='/dev/mapper/root'
notify 'Creating the encrypted root partition..'
cryptsetup -y -v luksFormat "$enc"

root_uuid=$(blkid "$enc" | awk -F '"' '{print $2}')

# Double check to make sure that this is the UUID of the device
if [[ $(blkid "$enc") != *"UUID=\"${root_uuid}\""* ]]; then
	echo "error: invalid UUID for '${enc}'. Aborting installation.."
	exit 1
fi

# Check CPU vendor
cpu_vendor=$(lscpu | grep '^Vendor ID:' | awk '{print $3}')
if [[ "$cpu_vendor" == 'AuthenticAMD' ]]; then
	notify 'Detected CPU vendor: AMD'
	microcode_pkg='amd-ucode'
elif [[ "$cpu_vendor" == 'GenuineIntel' ]]; then
	notify 'Detected CPU vendor: Intel'
	microcode_pkg='intel-ucode'
else
	echo 'error: unrecognized CPU vendor. Aborting installation..'
	exit 1
fi

notify 'Opening the encrypted root partition. Please enter your password.'
cryptsetup open "$enc" $(basename "$root")

notify "Making ext4 filesystem on '$root'"
mkfs.ext4 "$root"
notify "Mounting '$root' on '/mnt'"
mount /dev/mapper/root /mnt

notify "Mounting '$efi' on '/mnt/efi'"
mount --mkdir "$efi" /mnt/efi

notify "Installing Arch Linux on '/mnt'.."
pacstrap -K /mnt base linux linux-lts linux-firmware plymouth networkmanager sbctl efibootmgr $microcode_pkg
notify 'Generating fstab file..'
genfstab -U /mnt > /mnt/etc/fstab

notify 'Setting timezone..'
timezone=$(curl --fail 'https://ipapi.co/timezone' || exit)
if [[ ! -e "/mnt/usr/share/zoneinfo/$timezone" ]]; then
	echo "error: '/mnt/usr/share/zoneinfo/$timezone' does not exist. Aborting installation.."
	exit 1
fi

ln -sf /mnt/usr/share/zoneinfo/"$timezone" /mnt/etc/localtime

# https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#Mounting_the_devices
notify 'Configuring mkinitcpio hooks..'
sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard block encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

# Note 'modprobe.blacklist=sp5100_tc0' only needs to be disabled if using a AMD Ryzen CPU.
# See https://wiki.archlinux.org/title/Improving_performance#Watchdogs for more details.
notify 'Modifying kernel parameters..'
echo "BOOT_IMAGE=loglevel=3 quiet nmi_watchdog=0 nowatchdog audit=1 modprobe.blacklist=sp5100_tc0 cryptdevice=UUID=${root_uuid}:root root=/dev/mapper/root lsm=landlock,lockdown,yama,integrity,apparmor,bpf splash" > /mnt/etc/kernel/cmdline
echo "Whenever modifying the kernel's parameters be sure to run:
	'sbctl generate-bundles --sign'

Otherwise the changes will not be saved!" > /mnt/etc/kernel/READ_BEFORE_EDITING_CMDLINE

mkdir -p /mnt/efi/EFI/Linux
notify 'Signing kernel and microcode images for secure boot..'
if [[ "$cpu_vendor" == 'AuthenticAMD' ]]; then
	arch-chroot /mnt /bin/bash -c 'sbctl bundle -s -a /boot/amd-ucode.img -k /boot/vmlinuz-linux -f /boot/initramfs-linux.img -c /etc/kernel/cmdline /efi/EFI/Linux/Arch.efi'
	arch-chroot /mnt /bin/bash -c 'sbctl bundle -s -a /boot/amd-ucode.img -k /boot/vmlinuz-linux-lts -f /boot/initramfs-linux-lts.img -c /etc/kernel/cmdline /efi/EFI/Linux/ArchLTS.efi'
else
	echo 'error: Unknown CPU vendor. Aborting installation..'
	exit 1
fi

notify 'Setting up Secure Boot..'
arch-chroot /mnt /bin/bash -c 'sbctl create-keys'
arch-chroot /mnt /bin/bash -c 'sbctl generate-bundles --sign'
arch-chroot /mnt /bin/bash -c 'sbctl enroll-keys --microsoft'

if [[ "$efi" =~ ([0-9]+)$ ]]; then
	part_num="${BASH_REMATCH[1]}"
else
	echo "error: failed to extract partition number from $efi"
	exit 1
fi

notify 'Creating boot menu entry..'
# NVMEs have different naming conventions than the other SSDs and HDDs
# for some reason, so we have to account for that
if [[ "$efi" == 'nvme0n1'* ]]; then
	arch-chroot /mnt /bin/bash -c "efibootmgr --create --disk /dev/nvme0n1 --part $part_num --label \"Arch Linux\" --loader /EFI/Linux/Arch.efi"
	arch-chroot /mnt /bin/bash -c "efibootmgr --create --disk /dev/nvme0n1 --part $part_num --label \"Arch Linux LTS\" --loader /EFI/Linux/ArchLTS.efi"
else
	main_dev="${efi:0:-1}"
	arch-chroot /mnt /bin/bash -c "efibootmgr --create --disk $main_dev --part $part_num --label \"Arch Linux\" --loader /EFI/Linux/Arch.efi"
	arch-chroot /mnt /bin/bash -c "efibootmgr --create --disk $main_dev --part $part_num --label \"Arch Linux LTS\" --loader /EFI/Linux/ArchLTS.efi"
fi

INSTALL_DIR='/mnt/home/tmp'
notify "Creating temporary directory '$INSTALL_DIR'.."
mkdir -p "$INSTALL_DIR"
notify "Copying installation files to '$INSTALL_DIR' for stage 2.."
cp ./stage2.sh "$INSTALL_DIR"
cp ./.git-credentials "$INSTALL_DIR"
cp ./dotfiles.tar.gz "$INSTALL_DIR"

arch-chroot /mnt /bin/bash -c '/home/tmp/stage2.sh'



