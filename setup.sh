#!/bin/bash -xe

### Variable ###

hostname="void"
username="sleepy"
user_groups="wheel,audio,video"

efi_part_sz="260M"
language="en_US.UTF-8"
arch="x86_64"
repo="https://repo-default.voidlinux.org"

system_app="base-system grub-x86_64-efi pam_rundir dbus dhcpcd void-repo-nonfree"

user_app="intel-ucode git zip unzip p7zip curl wget xorg-minimal dejavu-fonts-ttf xclip \
    alsa-utils alsa-plugins-pulseaudio pavucontrol firefox keepassxc \
    xdg-dbus-proxy  xdg-user-dirs xdg-utils \
    libavcodec i3-gaps i3status-rust rofi neovim kitty feh xsetroot"

rm_services=("agetty-tty3" "agetty-tty4" "agetty-tty5" "agetty-tty6")
en_services=("dbus" "dhcpcd" "udevd")

### DISK ###
PS3="Select disk for installation: "
select line in $(fdisk -l | grep -v mapper | grep -o '/.*GiB' | tr -d ' '); do
    echo "Selected disk: $line"
    DISK_SELECTED=$(echo $line | sed 's/:.*$//')
    break
done

#Check type of disk
if [[ $DISK_SELECTED == *"nvme"* ]]; then
    select l in $(fdisk -l | grep -v mapper | grep -o '/.*GiB' | tr -d ' '); do
        echo "Selected disk: $l"
        HOME_DISK_SELECTED=$(echo $l | sed 's/:.*$//')
        break
    don
    EFI_PART=$(echo $DISK_SELECTED'p1')
    ROOT_PART=$(echo $DISK_SELECTED'p2')
    HOME_PART=$(echo $HOME_DISK_SELECTED'1')
    system_app="$system_app libvirt qemu virt-manager"
    user_app="$user_app nvidia"
    en_services="$en_services libvirtd virtlockd virtlogd"
    user_groups="$user_groups,kvm,libvirt"
fi

if [[ $DISK_SELECTED == *"vd"* ]]; then
    EFI_PART=$(echo $DISK_SELECTED'1')
    ROOT_PART=$(echo $DISK_SELECTED'2')
fi

#Wipe disk select
wipefs -faq $DISK_SELECTED

#Format disk as GPT, create EFI partition with size selected above and a 2nd partition with the remaining disk space
printf 'label: gpt\n, %s, U, *\n, , L\n' "$efi_part_sz" | sfdisk -q "$DISK_SELECTED"

#Create/mount system partition
mkfs.ext4 -L voidlinux $ROOT_PART
mkfs.vfat -n boot $EFI_PART
mount $ROOT_PART /mnt
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

if [[ $HOME_PART == *"/dev"*  ]]; then
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home
fi

#Copy the RSA keys from the installation medium to the target root directory
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

#Install system package
echo y | xbps-install -SyR $repo/current -r /mnt $system_app

#Create/mount virtual filesystem location under the root directory
for dir in dev proc sys run; do
    mkdir -p /mnt/$dir
    mount --rbind /$dir /mnt/$dir
    mount --make-rslave /mnt/$dir
done

#Copy DNS configuration to the new root
cp /etc/resolv.conf /mnt/etc/

#Add hostname and language
echo $hostname >/mnt/etc/hostname
echo "LANG=$LANGUAGE" >/mnt/etc/locale.conf
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/default/libc-locales

#Set localtime
chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime

#Generate locale files
chroot /mnt xbps-reconfigure -f glibc-locales

#Set fstab
uuid_uefi=$(blkid -s UUID -o value $EFI_PART)
uuid_root=$(blkid -s UUID -o value $ROOT_PART)
echo -e "UUID=$uuid_uefi  /boot/efi	vfat defaults 0	2" >> /mnt/etc/fstab
echo -e "UUID=$uuid_root	/	ext4	defaults 0 1" >> /mnt/etc/fstab

if [[ $HOME_PART == *"/dev"*  ]]; then
    uuid_home=$(blkid -s UUID -o value "$HOME_PART")
    echo -e "UUID=$uuid_home /home ext4 defaults 0 2" >>/mnt/etc/fstab
    mkdir -p /mnt/hugepages
    echo -e "hugetlbfs /hugepages hugetlbfs mode=1770,gid=1000 0 0" >> /mnt/etc/fstab
fi

# Miminal dracut
echo "hostonly=yes" >/mnt/etc/dracut.conf

#Modify GRUB config 
if [[ $system_app == *"qemu"* ]]; then
    kernel_params="intel_iommu=on iommu=pt"
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$kernel_params /" /mnt/etc/default/grub
fi
sed -i "s/loglevel=4/loglevel=1/" /mnt/etc/default/grub

# Set bootloader
# Detect if this is an EFI system.
if [ -e /sys/firmware/efi/systab ]; then
    EFI_FW_BITS=$(cat /sys/firmware/efi/fw_platform_size)
    if [ $EFI_FW_BITS -eq 32 ]; then
        EFI_TARGET=i386-efi
    else
        EFI_TARGET=x86_64-efi
    fi
fi

chroot /mnt grub-install --target=$EFI_TARGET --efi-directory=/boot/efi --bootloader-id=Void --recheck
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg


#Allow users in the wheel group to use sudo
sed -i "s/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL) ALL/" /mnt/etc/sudoers
#sed -i "s/# Cmnd_Alias    REBOOT/Cmnd_Alias      REBOOT/" /mnt/etc/sudoers

#Add folder for XDG_RUNTIME_DIR
#echo -e "mkdir /run/user/1000 \nchown sleepy:sleepy /run/user/1000 \nchmod 700 /run/user/1000" >> /mnt/etc/rc.local
echo "session         optional        pam_rundir.so" >> /mnt/etc/pam.d/login

#Config perm for libvirt/qemu
sed -i "/^#unix_sock_group/s/.//" /mnt/etc/libvirt/libvirtd.conf 
sed -i "/^#unix_sock_rw_perms/s/.//" /mnt/etc/libvirt/libvirtd.conf 
sed -i "s/\#user = \"libvirt\"/user = \"sleepy\"/" /mnt/etc/libvirt/qemu.conf
sed -i "s/\#group = \"libvirt\"/group = \"sleepy\"/" /mnt/etc/libvirt/qemu.conf

#Install user app
chroot /mnt xbps-install -Suy xbps $user_app

#Disable services as selected above
for service in ${rm_services[@]}; do
	if [[ -e /mnt/etc/runit/runsvdir/default/$service ]]; then
		chroot /mnt rm /etc/runit/runsvdir/default/$service
    chroot /mnt touch /etc/sv/$service/down
	fi
done

#Enable services as selected above
for service in ${en_services[@]}; do
	if [[ ! -e /mnt/etc/runit/runsvdir/default/$service ]]; then
		chroot /mnt ln -s /etc/sv/$service /etc/runit/runsvdir/default/
	fi
done

#Create non-root user and add them to group(s)
if [[ $HOME_PART == *"/dev"* ]]; then
    chroot /mnt useradd -d /home/$username $username
    chroot /mnt usermod -aG $user_groups $username
fi

#Use the "HereDoc" to send a sequence of commands into chroot, allowing the root and non-root user passwords in the chroot to be set non-interactively
declare root_pw user_pw
echo -e "\nEnter password to be used for the root user\n"
read root_pw
echo -e "\nEnter password to be used for the user account\n"
read user_pw
cat << EOF | chroot /mnt
echo "$root_pw\n$root_pw" | passwd -q root
echo "$user_pw\n$user_pw" | passwd -q $username
EOF

#Ensure an initramfs is generated
chroot /mnt xbps-reconfigure -fa

read tmp
if [[ $tmp == "y" ]]; then
	umount -R /mnt #Unmount root volume
	reboot
fi
