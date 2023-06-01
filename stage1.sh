#!/bin/bash

bolden() {
	tput bold
	echo -e "$1"
	tput sgr0
}

notify() {
	tput bold
	tput setaf "$blue"
	echo ':: ' | tr -d '\n'
	tput setaf "$white"
	echo "$1"
	tput sgr0
}

if [[ ! -f './dotfiles.tar.gz' ]]; then
	echo error: unable to find './dotfiles.tar.gz'. Aborting installation
	exit 1
fi

if [[ ! -f './.git-credentials' ]]; then
	echo error: unable to find './.git-credentials'. Aborting installation
	exit 1
fi

read -p "Before continuing, this installation script assumes you've created your /boot and / partitions.\
It also assumes that the machine has functional internet access. If you've done both of these things, \
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
	echo "error: '$efi' is not a valid EFI partition. In order to make it so type: "
	bolden "		mkfs.fat -F32 $efi"
	echo 'Be sure to erase everything in the partition before doing this!'
	exit 1
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

notify 'Opening the encrypted root partition. Please enter your password.'
cryptsetup open "$enc" $(basename "$root")

notify "Making ext4 filesystem on '$root'"
mkfs.ext4 "$root"
notify "Mounting '$root' on '/mnt'"
mount /dev/mapper/root /mnt

notify "Mounting '$efi' on '/mnt/boot'"
mount --mkdir "$efi" /mnt/boot

notify "Installing Arch Linux on '/mnt'"
pacstrap -K /mnt base linux linux-firmware plymouth networkmanager grub efibootmgr
notify 'Generating fstab file..'
genfstab -U /mnt >> /mnt/etc/fstab

notify 'Setting timezone..'
timezone=$(curl --fail 'https://ipapi.co/timezone' || exit)
if [[ ! -e "/mnt/usr/share/zoneinfo/$timezone" ]]; then
	echo "error: '/mnt/usr/share/zoneinfo/$timezone' does not exist. Aborting installation.."
	exit 1
fi

ln -sf /mnt/usr/share/zoneinfo/"$timezone" /mnt/etc/localtime

notify "Installing GRUB on '/mnt/boot'"
arch-chroot /mnt /bin/bash -c 'grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB'

notify "note: UUID of '$enc' is '$root_uuid'"
# Note 'modprobe.blacklist=sp5100_tc0' only needs to be disabled if using a AMD Ryzen CPU.
# See https://wiki.archlinux.org/title/Improving_performance#Watchdogs for more details.
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet nmi_watchdog=0 nowatchdog audit=1 modprobe.blacklist=sp5100_tc0 cryptdevice=UUID=${root_uuid}:root root=\/dev\/mapper\/root lsm=landlock,lockdown,yama,integrity,apparmor,bpf splash\"/" /mnt/etc/default/grub
notify 'Generating new GRUB configuration file..'

INSTALL_DIR='/mnt/home/tmp'
notify "Creating temporary directory '$INSTALL_DIR'.."
mkdir -p "$INSTALL_DIR"
notify "Copying installation files to '$INSTALL_DIR' for stage 2.."
cp ./stage2.sh "$INSTALL_DIR"
cp ./.git-credentials "$INSTALL_DIR"
cp ./dotfiles.tar.gz "$INSTALL_DIR"

arch-chroot /mnt /bin/bash -c '/home/tmp/stage2.sh'



