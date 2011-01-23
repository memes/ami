#! /bin/sh
#
# Simple shell script to create a CentOS image suitable for EC2
# deployment
#
# $Id: $

NO_TEST=${NO_TEST:-""}
NO_TEST_LAUNCH=${NO_TEST_LAUNCH:-""}
CENTOS_VER=${CENTOS_VER:-5.5}
AMI_ARCH=${AMI_ARCH:-i386}
MIRROR_URL=${MIRROR_URL:-"http://mirror.centos.org/centos/${CENTOS_VER}"}
BASEDIR=${BASEDIR:-"$(pwd)/centos_${CENTOS_VER}_${AMI_ARCH}"}
MOUNTDIR=${MOUNTDIR:-"$(pwd)/centos_${CENTOS_VER}_${AMI_ARCH}.mnt"}
ROOT_PKGS=${ROOT_PKGS:-"yum-utils"}
BASE_PKGS=${BASE_PKGS:-"passwd vim-minimal sudo openssh-server man shadow-utils authconfig dhclient postfix"}
EXTRA_PKGS=${EXTRA_PKGS:-"subversion mercurial"}
# Use a random password for memes account; public key SSH only
MEMES_PASSWORD=$(dd if=/dev/urandom bs=1 count=8 | base64)

# Source the common functions
[ -r "$(dirname $0)/ami_functions.sh" ] && . $(dirname $0)/ami_functions.sh
[ -r "$(dirname $0)/../ami_functions.sh" ] && \
    . $(dirname $0)/../ami_functions.sh
type add_memes_keys >/dev/null 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$0: Error: required functions in ami_functions are not available" >&2
    exit 1
fi

script_version="$(basename $0)"

# Make sure environment is correct and ROOT_PKGS are specified
ec2_validate
prebuild_validate
[ -z "${ROOT_PKGS}" ] && error "No root packages specified in \${ROOT_PKGS}"

# After execution remount /home without dev support and unbind shared systems
trap cleanup 0 1 2 3 15

# Prepare $BASEDIR for installation
rm_chroot "${BASEDIR}"
mkdir -p "${BASEDIR}/etc/yum.repos.d"
[ -d "${BASEDIR}/etc/yum.repos.d" ] || \
    error "preparing to install: ${BASEDIR}/etc/yum.repos.d does not exist"

# Prepare for yum installation
if [ "i386" = "${AMI_ARCH}" ]; then
    # Force i386 installation because the host may be x86_64
    EXCLUDE="--exclude '*.x86_64'"
    sudo mkdir -p "${BASEDIR}/etc/rpm"
    [ -d "${BASEDIR}/etc/rpm" ] || \
	    error "preparing to install: ${BASEDIR}/etc/rpm does not exist"
    sudo sh -c "echo \"i686-memes-linux-gnu\" >> \"${BASEDIR}/etc/rpm/platform\""
    [ -s "${BASEDIR}/etc/rpm/platform" ] || \
	    error "preparing to install: ${BASEDIR}/etc/rpm/platform is missing or empty"
fi
if [ "x86_64" = "${AMI_ARCH}" ]; then
    # Try to keep the install pure x86_64; exclude i386 packages by default
    EXCLUDE="--exclude '*.i?86'"
fi

cat > "/tmp/yum.conf" <<EOF
[main]
cachedir=/var/cache/yum
persistdir=/var/lib/yum
keepcache=1
debuglevel=2
errorlevel=2
logfile=/var/log/yum.log
gpgcheck=0
tolerant=1
exclude=*-debuginfo
exactarch=1
obsoletes=1
distroverpkg=redhat-release
reposdir=/etc/yum.repos.d
plugins=1
EOF

sudo sh -c "cat > \"${BASEDIR}/etc/yum.repos.d/memes.repo\"" <<EOF
# Repositories to use during installation that are certain to be the
# architecture wanted, not the architecture of the host machine
[memes_os]
name=CentOS ${CENTOS_VER} - ${AMI_ARCH} - OS
mirrorlist=http://mirrorlist.centos.org/?release=${CENTOS_VER}&arch=${AMI_ARCH}&repo=os
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5
enabled=1

[memes_updates]
name=CentOS ${CENTOS_VER} - ${AMI_ARCH} - Updates
mirrorlist=http://mirrorlist.centos.org/?release=${CENTOS_VER}&arch=${AMI_ARCH}&repo=updates
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5

[memes_epel]
name=Extra Packages for Enterprise Linux 5 - ${AMI_ARCH}
mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=epel-5&arch=${AMI_ARCH}
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL
EOF

# Install minimum set of packages in order to get functional system
# Note: these will need to be reinstalled within the chroot to resolve
# host/chroot rpm/yum/db differences
sudo yum -c /tmp/yum.conf -y --installroot="${BASEDIR}" ${EXCLUDE} \
    --disablerepo="*" --enablerepo="memes*" install ${ROOT_PKGS}
sudo rm -rf "${BASEDIR}/root/.rpmdb"

# The install above may have used different db version for RPM, so reinstall
# everything in the chroot to make sure the environment is configured correctly
prepare_chroot "${BASEDIR}"
sudo chroot "${BASEDIR}" <<EOF
# prepare for reinstall of packages
touch /etc/mtab
rpm --initdb

# Reinstall and clean up rpmnew files that were generated as a result
# Note: the set of ROOT_PKGS should have been cached by the initial population
# of rpms outside of the chroot so only the BASE_PKGS should need to be
# downloaded in the chroot
yum -y ${EXCLUDE} --disablerepo="*" --enablerepo="memes*" \
    install ${ROOT_PKGS} ${BASE_PKGS}
yum-complete-transaction -y ${EXCLUDE}
find / -iname "*rpmnew" -exec rm -f {} \;

# Don't need the memes repo definitions at this point
rm -rf /etc/yum.repos.d/memes.repo /var/cache/yum/memes*

# Clean up all yum repository information
yum -y clean all

# Set the time and timezone for the instance
cat >> /etc/sysconfig/clock <<eof
TIMEZONE="America/Los_Angeles"
UTC=true
ARC=false
eof
rm -f /etc/localtime && \
    ln /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
cat >> /etc/profile.d/timezone.sh <<eof
TZ=America/Los_Angeles
export TZ
eof
cat >> /etc/profile.d/timezone.csh <<eof
setenv TZ America/Los_Angeles
eof

# Disable TLS when running under xen
cat >> /etc/ld.so.conf.d/xen.conf <<eof
# Disable TLS when the image is running under xen
hwcap 0 nosegneg
eof
ldconfig

# At this point the chroot contains a working minimal set of packages; start to
# customise the install for EC2

# Install the EPEL repo package to get the signing key and access to mercurial, 
# etc
rpm -Uvh --nosignature \
    http://download.fedora.redhat.com/pub/epel/5/${AMI_ARCH}/epel-release-5-4.noarch.rpm
# Recreate required devices
/sbin/MAKEDEV -a mem null port zero core full ram tty console random urandom

# Enable networking
cat > /etc/sysconfig/network <<eof
NETWORKING=yes
eof
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 <<eof
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=yes
PEERDNS=yes
IPV6INIT=no
eof
cat > /etc/hosts <<eof
127.0.0.1       localhost
# IPv6 entries
::1     localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
eof

# Update sudoers file
cat >> /etc/sudoers <<eof
aaxis ALL=(ALL) ALL
# memes password is random, so don't prompt for sudo
memes ALL=(ALL) NOPASSWD:ALL
eof

# Configure authentication
authconfig --enablemd5 --enableshadow --updateall

# Install the extra packages
[ -n "${EXTRA_PKGS}" ] && yum -y ${EXCLUDE} install ${EXTRA_PKGS}

# Make sure rsyslog, networking and email services are enabled
chkconfig --level 2345 rsyslog on
chkconfig --level 2345 network on
chkconfig --level 2345 postfix on

# Change root password to consistent value across instances, but
# remote login is permitted only by public SSH key
echo "REPLACE_ME" | passwd --stdin root
mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys2
chmod 0700 /root/.ssh
chmod 0600 /root/.ssh/authorized_keys2
chown -R root:root /root/.ssh

# Add an Aaxis user for consistent access
useradd -c "Default Aaxis user" -m aaxis
mkdir -p /home/aaxis/.ssh
touch /home/aaxis/.ssh/authorized_keys2
chmod 0700 /home/aaxis/.ssh
chmod 0600 /home/aaxis/.ssh/authorized_keys2
chown -R aaxis:aaxis /home/aaxis/.ssh

# Add memes with random password
useradd -c "Matthew Emes" -m memes
echo "${MEMES_PASSWORD}" | passwd --stdin memes
mkdir -p /home/memes/.ssh
touch /home/memes/.ssh/authorized_keys2
chmod 0700 /home/memes/.ssh
chmod 0600 /home/memes/.ssh/authorized_keys2
chown -R memes:memes /home/memes/.ssh
EOF

post_chroot "${BASEDIR}"
update_fstab "${BASEDIR}"
update_sshd "${BASEDIR}"
add_memes_keys "${BASEDIR}"

# Clean up
sudo rm -f "${BASEDIR}/root/.*history"
[ -e "${BASEDIR}/etc/rpm/platform" ] && \
    grep -qa memes "${BASEDIR}/etc/rpm/platform" >/dev/null 2>/dev/null && \
    sudo rm -f "${BASEDIR}/etc/rpm/platform"

# Prepare an AMI for upload
ami_img="${BASEDIR}.ec2.img"
mk_fs_image "${ami_img}" $((1024 * 1024 * 1024))
mount_img "${MOUNTDIR}"
sudo rsync -avP "${BASEDIR}/" "${MOUNTDIR}/" || \
    error "rsync returned error code $?"
umount_img "${MOUNTDIR}"
bundle_ami "${ami_img}"
ami_name="centos_${CENTOS_VER}_${AMI_ARCH}.$(date +%Y%m%d)"
description="CentOS ${CENTOS_VER} ${AMI_ARCH} created $(date "+%H:%M %Z on %Y/%m/%d") by ${script_version}"
upload_ami $(basename "${ami_img}") "matthewemes.com/ami" "${ami_name}" "${description}"

# Shall a test image be launched in KVM?
[ -n "${NO_TEST}" ] && exit

# Make a 1Gb test image for KVM verification
kvm_img="${BASEDIR}.kvm.img"
mk_disk_image "${kvm_img}" $((1024 * 1024 * 1024))
mount_img "${MOUNTDIR}"
sudo rsync -avP "${BASEDIR}/" "${MOUNTDIR}/" || \
    error "rsync returned error code $?"

# Modify filesystem for use with KVM
kvm_compatible_fs "${MOUNTDIR}"

# Install a kernel for testing
prepare_chroot "${MOUNTDIR}"
sudo chroot "${MOUNTDIR}" yum -y ${EXCLUDE} install kernel
post_chroot "${MOUNTDIR}"

# Install GRUB and unmount
mk_bootable "${MOUNTDIR}"
umount_img "${MOUNTDIR}"

[ -n "${NO_TEST_LAUNCH}" ] && exit

# Launch in KVM
cleanup
ismounted "${MOUNTDIR}/proc" && error "${MOUNTDIR}/proc is still mounted"
ismounted "${MOUNTDIR}/sys" && error "${MOUNTDIR}/sys is still mounted"
ismounted "${MOUNTDIR}" && error "${MOUNTDIR} is still mounted"
isloop "${part_dev}" && error "${part_dev} is still active"
isloop "${img_dev}" && error "${img_dev} is still active"

launch_img "${BASEDIR}.kvm.img"