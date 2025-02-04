#
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
export PATH

set -e

#
r=/targetroot
release=9.2

# disk partition
cat <<EOF > /tmp/sed.$$
/total sectors:/{
s/.*sectors: //
s/,.*//
p
q
}
EOF
wd_size="$(fdisk wd0d | sed -n -f /tmp/sed.$$)"
fdisk -i -a -0 -f -u -s 169/63/$(($wd_size - 63)) /dev/rwd0d

# disklabel
ram_size="$(sysctl -n hw.physmem)"
swap_size="$(($ram_size / 512))"
root_size="$(($wd_size - 63 - $swap_size))"
disklabel -t wd0 > /tmp/disktab.$$ || true # XXX
sed -e "s/generated label/generated label|mylabel/" \
    -e "s/:pe#.*/:pa#$root_size:oa#63:ta=4.2BSD:ba#16384:fa#2048:pb#$swap_size:ob#$(($root_size + 63)):tb=swap:/" \
    /tmp/disktab.$$ > /tmp/newdisktab.$$
disklabel -w -f /tmp/newdisktab.$$ wd0 mylabel

# newfs
newfs -O 2 /dev/rwd0a

# mount root
mount -o async /dev/wd0a $r

# handle gzip and xz compressed sets
suffix=tgz
[ -f /amd64/binary/sets/base.tar.xz ] && suffix=tar.xz
# extract sets
sets="base etc comp games kern-GENERIC man misc modules tests text xbase xcomp xetc xfont xserver"
for s in $sets; do
  ( cd $r && tar --chroot -xzpf /amd64/binary/sets/$s.$suffix )
done

# MAKEDEV
( cd $r/dev && sh ./MAKEDEV all )

# fstab
mkdir $r/kern
mkdir $r/proc
cat <<EOF > $r/etc/fstab
/dev/wd0a /    ffs  rw,log 1 1
/dev/wd0b none swap sw,dp  0 0
kernfs /kern kernfs rw 0 0
procfs /proc procfs rw 0 0
fdesc /dev fdesc ro,-o=union 0 0
ptyfs /dev/pts ptyfs rw 0 0
tmpfs /tmp tmpfs rw,-m1777,-sram%25
EOF

# fdescfs is broken in 9.0 and 9.1
case $(uname -r) in
  9.[01])
    ed -s $r/etc/fstab <<EOF
/^fdesc/s/union/&,noauto/
wq
EOF
    ;;
esac

# installboot
chroot $r cp /usr/mdec/boot /boot
chroot $r /usr/sbin/installboot  /dev/rwd0a /usr/mdec/bootxx_ffsv2

# root password
passhash="$(chroot $r pwhash vagrant)"
sed -e "s,^root::,root:$passhash:," $r/etc/master.passwd > /tmp/master.passwd
cp /tmp/master.passwd $r/etc/master.passwd
chown 0:0 $r/etc/master.passwd
chmod 600 $r/etc/master.passwd
chroot $r pwd_mkdb -p /etc/master.passwd

# hostname & network config
cat <<EOF >> $r/etc/rc.conf
hostname=vagrant
ifconfig_wm0=dhcp
EOF

# ssh config
cat <<EOF >> $r/etc/ssh/sshd_config
UseDNS no
NoneEnabled yes
EOF
echo sshd=YES >> $r/etc/rc.conf

# misc configuration
echo wscons=YES >> $r/etc/rc.conf
sed -e 's/^rc_configured=NO/rc_configured=YES/' $r/etc/rc.conf > /tmp/rc.conf
cp /tmp/rc.conf $r/etc/rc.conf

# kill dhcpcd and relaunch it in chroot
dhcpcd -4 -x wm0
chroot $r dhcpcd -4 -w wm0

# setup pkgin
chroot $r pkg_add http://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/$release/All/pkgin
sed -e 's,^[^#].*$,http://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$arch/'$release'/All,' $r/usr/pkg/etc/pkgin/repositories.conf > /tmp/repositories.conf
mv /tmp/repositories.conf $r/usr/pkg/etc/pkgin/repositories.conf
chroot $r pkgin -y update

# install some packages for vagrant user
chroot $r /usr/pkg/bin/pkgin -y install bash sudo

# vagrant user
chroot $r useradd -s /usr/pkg/bin/bash -d /home/vagrant -m -g staff -G wheel -p "$passhash" vagrant
mkdir -pm 700 $r/home/vagrant/.ssh
chroot $r ftp -o /home/vagrant/.ssh/authorized_keys 'https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub'
chmod 0600 $r/home/vagrant/.ssh/authorized_keys
chroot $r chown -R vagrant /home/vagrant/.ssh
echo "vagrant ALL=(ALL) NOPASSWD: ALL" >> $r/usr/pkg/etc/sudoers.d/vagrant
chmod 0400 $r/usr/pkg/etc/sudoers.d/vagrant

# stop dhcpcd so that we can unmount $r
chroot $r dhcpcd -4 -x wm0

# flush dirty buffers to disk
umount $r
