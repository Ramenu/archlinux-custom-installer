#!/bin/bash

#set -e

cyan=14
blue=12
green=10
red=9
yellow=11
white=15
pink=13

title() {
	echo ''
	tput bold
	tput setaf "$white"
	echo "$1"
	tput setaf "$blue"
	for (( i=0; i<${#1}; i++ )); do
		echo - | tr -d '\n'
	done
	echo ''
	tput sgr0
}

install_package() {
	pacman -Syu --noconfirm "$@" #|| exit 1
}

notify() {
	tput bold
	tput setaf "$blue"
	echo ':: ' | tr -d '\n'
	tput setaf "$white"
	echo "$1"
	tput sgr0
}

cd /tmp
title "Welcome to Ramenu's Post-Arch Install Script"

echo "Before continuing, make sure you read the instructions carefully.

1) Make sure you're running this script as root.

2) This script is intended to work on Arch Linux primarily. There are several
AUR packages that will be installed during the process. It also assumes that you
only have the core components installed. While this can work for some Arch
derivatives, be mindful that something may break.

3) It assumes you have GRUB installed as your bootloader.

4) It assumes you're running this script on a desktop machine.

5) Make sure you have your unencrypted dotfiles archive in the same directory that you're running this script in.

6) This script and all of the required files must be executed and placed in '/tmp'.

7) Make sure you have your '.git-credentials' file stored in '/tmp'.

8) This script is intended to be used by me only. 

9) I am not responsible for any damages that this script might cause to your system, wellbeing, or family. Good luck.

I acknowledge that I have read these instructions. [y/n]"
read resp

if [[ "$resp" != "y" ]]; then
	echo Aborting installation
	exit
fi

tput sgr0

if [[ "$(pwd)" != "/tmp" ]]; then
	echo error: script must be run in '/tmp'. Aborting installation
	exit 1
fi

if [[ ! -f '/tmp/dotfiles.tar.gz' ]]; then
	echo error: unable to find '/tmp/dotfiles.tar.gz'. Aborting installation
	exit 1
fi

if [[ ! -f '/tmp/.git-credentials' ]]; then
	echo error: unable to find '/tmp/.git-credentials'. Aborting installation
	exit 1
fi

read -p 'Is your device a laptop? [y/n] ' is_laptop
read -p 'Is your Arch Linux installation on a LUKS partition? [y/n] ' encrypted
echo What do you want your account\'s username to be?
read username

echo "Creating new user '$username'"
useradd -m -G wheel -s /bin/bash "$username"
passwd "$username"

echo "$is_laptop"
if [[ "$is_laptop" == "y" ]]; then
	notify 'Installing TLP (for optimizing battery usage)..'
	install_package tlp
	systemctl enable tlp.service
fi

if [[ "$encrypted" == "y" ]]; then
	echo Enter the UUID of the encrypted partition. You can find it by running 'blkid'
	read enc_part_uuid

	# https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#Mounting_the_devices
	echo Configuring mkinitcpio hooks..
	sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf

	echo Regenerating all initramfs images..
	mkinitcpio -P
fi

notify 'Installing essential security components...'
install_package ufw apparmor

notify 	'	-> Enabling firewall'; systemctl enable ufw.service; ufw enable
notify  '	-> Enabling AppArmor'; systemctl enable apparmor.service
notify 	'	-> Enabling fstrim.timer'; systemctl enable fstrim.timer

notify 'Changing kernel parameters..'
notify '	-> Disabling watchdog timer..'
notify '	-> Enabling AppArmor as default security model on boot..'

# Note 'modprobe.blacklist=sp5100_tc0' only needs to be disabled if using a AMD Ryzen CPU.
# See https://wiki.archlinux.org/title/Improving_performance#Watchdogs for more details.
if [[ "$encrypted" == "y" ]]; then
	sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet nmi_watchdog=0 nowatchdog modprobe.blacklist=sp5100_tc0 cryptdevice=UUID=${enc_part_uuid}:root root=/dev/mapper/root lsm=landlock,lockdown,yama,integrity,apparmor,bpf/" /etc/default/grub
else
	sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet nmi_watchdog=0 nowatchdog modprobe.blacklist=sp5100_tc0 lsm=landlock,lockdown,yama,integrity,apparmor,bpf/" /etc/default/grub
fi

notify "Installing 'base-devel' package"; install_package base-devel
notify 'Installing sudo (lol)..'; install_package sudo
notify 'Installing git..'; install_package git
notify 'Installing yay AUR helper..'

echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers
sudo -u "$username" git clone https://aur.archlinux.org/yay-bin.git || exit

read -p 'View PKGBUILD? [y/n] ' view_pkgbuild

if [[ "$view_pkgbuild" == "y" ]]; then
	less ./yay-bin/PKGBUILD
	read -p 'Proceed with installation? [y/n] ' install_yay

	if [[ "$install_yay" != "y" ]]; then
		echo 'Aborting installation'
		exit 1
	fi
fi

cd ./yay-bin && sudo -u "$username" makepkg -si
cd ..
rm -r ./yay-bin

# https://wiki.archlinux.org/title/PC_speaker
notify 'Disabling annoyingly loud PC speaker..'
echo -e 'blacklist pcspkr\nblacklist snd_pcsp' > /etc/modprobe.d/nobeep.conf

read -p "Do you have a NVIDIA GPU and do you require proper drivers for it? (Type 'n' if on a virtual machine) [y/n] " nvidia

if [[ "$nvidia" == "y" ]]; then
	notify 'Installing NVIDIA drivers..'
	install_package nvidia-open
fi

notify 'Installing additional packages..'
install_package  mesa xorg xfce4 opensnitch \
	             keepassxc syncthing firefox pipewire \
				 pipewire-pulse pipewire-audio wireplumber \
				 xfce4-genmon-plugin xclip gvfs gvfs-afc \
				 thunar thunar-volman neovim stow python \
				 python-qt-material python-pyasn zsh \
				 wireguard-tools networkmanager

notify 'Enabling opensnitchd to run at startup'; systemctl enable opensnitchd.service
notify 'Enabling NetworkManager to run at startup'; systemctl enable NetworkManager.service

notify 'Installing additional AUR packages (it is highly recommended that you take a look at all the PKGBUILDs before installing!)'
sudo -u "$username" yay -Syu visual-studio-code-bin searxng-git

notify 'Setting slock as the default screenlocker..'
xfconf-query --create -c xfce4-session -p /general/LockCommand -t string -s 'slock'

cd /tmp
chown "$username":"$username" ./dotfiles.tar.gz
chown "$username":"$username" ./.git-credentials
notify "Extracting dotfiles archive to /home/$username/dotfiles"
tar -zxvf ./dotfiles.tar.gz -C "/home/$username"
notify 'Running initdot.py'
cd "/home/$username/dotfiles"
python ./initdot.py
notify 'Successfully installed dotfiles..'
cd /tmp

notify "Creating '/home/$username/projects'.."
sudo -u "$username" mkdir "/home/$username/projects"
cd "/home/$username/projects"

notify "Installing additional packages from the 'rm-extra' repository.."
pacman -Syu paccheck-git quikc

# Save Git credentials so the user doesn't have to automatically type
# in their username and password every time
sudo -u "$username" git config --global credential.helper store
sudo -u "$username" cp /tmp/.git-credentials "/home/$username"
notify 'Cloning essential repositories..'
sudo -u "$username" git clone https://github.com/Ramenu/scripts || exit
sudo -u "$username" git clone https://github.com/Ramenu/greet || exit
notify "Compiling 'greet'.."
cd ./greet; sudo -u "$username" mkdir ./include && quikc

notify "Changing shell from /bin/bash to /bin/zsh for user $username"
sudo -u "$username" chsh -s /bin/zsh

notify "Rebooting system.. you can login as $username now."
reboot

# TODO: Edit the initdot.py script to not run as root. Only use sudo
# for folders that need the additional permissions
