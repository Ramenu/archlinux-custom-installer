#!/bin/bash

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
	pacman -Syu --color always --needed --noconfirm "$@" #|| exit 1
}

notify() {
	tput bold
	tput setaf "$yellow"
	echo ' -> ' | tr -d '\n'
	tput setaf "$white"
	echo "$1"
	tput sgr0
}

INSTALL_DIR='/home/tmp'
if [[ ! -f "$INSTALL_DIR/dotfiles.tar.gz" ]]; then
	echo "error: unable to find '$INSTALL_DIR/dotfiles.tar.gz'. Aborting installation"
	exit 1
fi

if [[ ! -f "$INSTALL_DIR/.git-credentials" ]]; then
	echo "error: unable to find '$INSTALL_DIR/.git-credentials'. Aborting installation"
	exit 1
fi

notify "Generating '/etc/adjtime'.."
hwclock --systohc
notify 'Generating locales..'
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
if [[ ! -f '/etc/hostname' ]]; then
	read -p "What do you want this computer's hostname to be? " hostname
	echo "$hostname" > /etc/hostname
fi

cd $INSTALL_DIR
tput sgr0

read -p 'Is your device a laptop? [y/n] ' is_laptop
read -p "What do you want your account's username to be? " username

echo "Creating new user '$username'"
useradd -m -G wheel -s /bin/bash "$username"
passwd "$username"

if [[ "$is_laptop" == "y" ]]; then
	notify 'Installing TLP (for optimizing battery usage)..'
	install_package tlp
	systemctl enable tlp.service
fi

notify 'Installing essential security components...'
install_package ufw apparmor

notify 	'	-> Enabling firewall'; systemctl enable ufw.service; ufw enable
notify  '	-> Enabling AppArmor'; systemctl enable apparmor.service
notify 	'	-> Enabling fstrim.timer'; systemctl enable fstrim.timer

notify 'Changing kernel parameters..'
notify '	-> Disabling watchdog timer..'
notify '	-> Enabling AppArmor as default security model on boot..'
notify '     -> Setting up splash screen..'


notify "Installing packages from group 'base-devel'.."; install_package base-devel
notify 'Installing git..'; install_package git
notify 'Installing less..'; install_package less

notify "Adding user '$username' as a sudoer"
echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

yay_pkg_dir='./yay-bin'
yay_pkg="$(basename $yay_pkg_dir)"
if ! pacman -Q $yay_pkg > /dev/null 2>&1; then
	cd /tmp
	notify 'Installing yay AUR helper..'
	sudo -u "$username" git clone https://aur.archlinux.org/$yay_pkg.git || exit

	read -p 'View PKGBUILD? [y/n] ' view_pkgbuild

	if [[ "$view_pkgbuild" == "y" ]]; then
		less $yay_pkg_dir/PKGBUILD
		read -p 'Proceed with installation? [y/n] ' install_yay

		if [[ "$install_yay" != "y" ]]; then
			echo 'Aborting installation'
			exit 1
		fi
	fi

	cd $yay_pkg_dir && sudo -u "$username" makepkg -si --needed
	cd ..
	rm -rf $yay_pkg_dir
fi

# https://wiki.archlinux.org/title/PC_speaker
notify 'Disabling annoyingly loud PC speaker..'
echo -e 'blacklist pcspkr\nblacklist snd_pcsp' > /etc/modprobe.d/nobeep.conf

read -p "Do you have a NVIDIA GPU? (Type 'n' if on a virtual machine) [y/n] " nvidia

if [[ "$nvidia" == "y" ]]; then
	notify 'Installing NVIDIA drivers..'
	install_package nvidia-open nvidia-lts
fi

notify 'Installing additional packages..'
install_package  mesa xorg xfce4 opensnitch \
	             keepassxc syncthing firefox pipewire \
				 pipewire-pulse pipewire-audio wireplumber \
				 xfce4-genmon-plugin xclip gvfs gvfs-afc \
				 thunar thunar-volman neovim python \
				 python-qt-material python-pyasn zsh \
				 wireguard-tools xfce4-taskmanager xfce4-pulseaudio-plugin \
				 tmux xdg-user-dirs audit bubblewrap \
				 xfce4-screensaver xarchiver \
				 zathura-pdf-poppler noto-fonts noto-fonts-cjk \
				 noto-fonts-emoji urlwatch gvfs-mtp kernel-modules-hook \
				 gnupg cowsay alacritty dmenu

notify 'Enabling opensnitchd to run at startup'; systemctl enable opensnitchd.service
notify 'Enabling NetworkManager to run at startup'; systemctl enable NetworkManager.service
notify 'Enabling audit framework daemon to run at startup'; systemctl enable auditd.service

notify 'Installing additional AUR packages (it is highly recommended that you take a look at all the PKGBUILDs before installing!)'
sudo -u "$username" yay -S --color always --needed adwaita-qt5-git candy-icons-git quikc-git

cd $INSTALL_DIR
chown "$username":"$username" ./dotfiles.tar.gz
chown "$username":"$username" ./.git-credentials
notify "Extracting dotfiles archive to /home/$username/dotfiles"
mkdir "/home/$username/dotfiles"
tar -zxvf ./dotfiles.tar.gz -C "/home/$username/dotfiles"
notify 'Running initdot.py'
cd "/home/$username/dotfiles"

# initdot.py needs to be run as the user and root separately
sudo -u "$username" python ./initdot.py --overwrite
python ./initdot.py --overwrite

notify 'Successfully installed dotfiles..'
cd $INSTALL_DIR


notify "Creating '/home/$username/projects'.."
sudo -u "$username" mkdir "/home/$username/projects"
cd "/home/$username/projects"

# Save Git credentials so the user doesn't have to automatically type
# in their username and password every time
sudo -u "$username" git config --global credential.helper store
sudo -u "$username" cp $INSTALL_DIR/.git-credentials "/home/$username"
notify 'Cloning essential repositories..'
sudo -u "$username" git clone https://github.com/Ramenu/scripts || exit
sudo -u "$username" git clone https://github.com/Ramenu/greet || exit
sudo -u "$username" git clone https://github.com/Ramenu/updpkgver || exit
notify "Compiling 'greet'.."
cd ./greet; sudo -u "$username" mkdir ./include && quikc

notify "Changing shell from /bin/bash to /bin/zsh for user $username"
sudo -u "$username" chsh -s /bin/zsh

# Make standard XDG directories
notify "Creating full suite of XDG directories in /home/$username"
sudo -u "$username" xdg-user-dirs-update

# Download wallpaper
notify "Downloading default wallpaper.. (stored in '/home/$username/Pictures'. You will have to set this manually)"
cd /tmp
sudo -u "$username" git clone https://github.com/Ramenu/Programming-Language-Tier-List
cd ./Programming-Language-Tier-List
mv ./81679.jpg /home/"$username"/Pictures/wallpaper.jpg

notify 'Allowing X to run with standard user privileges..'
echo 'needs_root_rights = no' > /etc/X11/Xwrapper.config

notify 'Generating and enforcing new AppArmor profiles...'
cp -r /home/"$username"/dotfiles/apparmor.d/* /etc/apparmor.d

# This increases the total number of virtual memory allocations a process
# can make (useful for games or other demanding applications).
# See: 
# 	https://www.suse.com/support/kb/doc/?id=000016692 
# 	https://fedoraproject.org/wiki/Changes/IncreaseVmMaxMapCount
vm_max_map_count=2147483642
notify "Changing maximum number of virtual memory allocations a process can make to $vm_max_map_count"
echo "vm.max_map_count=$vm_max_map_count" >> /etc/sysctl.d/99-sysctl.conf

notify 'Locking root account...'
passwd -l root
notify "Rebooting system.. you can login as $username now."
read -p 'Do you want to reboot the system? [y/n] ' rebootpc

notify "Removing all files from installation directory: '$INSTALL_DIR'"
cd /
rm -rf "$INSTALL_DIR"

if [[ "$rebootpc" == "y" ]]; then
	reboot
fi

