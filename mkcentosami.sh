# Simple shell script to create a CentOS image suitable for EC2
# deployment
#

CENTOS_VER=${CENTOS_VER:-5.5}
MIRROR_URL=${MIRROR_URL:-"http://mirror.centos.org/centos/${CENTOS_VER}"}
WORKINGDIR=${WORKINGDIR:-"$(pwd)"}
MOUNTDIR=${MOUNTDIR:-"$(pwd)/centos_${CENTOS_VER}_${AMI_ARCH}.mnt"}
ROOT_PKGS=${ROOT_PKGS:-"yum-utils"}
BASE_PKGS=${BASE_PKGS:-"passwd vim-minimal sudo openssh-server man shadow-utils authconfig dhclient postfix which mailx"}
EXTRA_PKGS="${EXTRA_PKGS} git s3cmd"

# Return the directory to use for base install
distro_get_base_directory()
{
    echo "${WORKINGDIR}/centos_${CENTOS_VER}_${AMI_ARCH}"
}

# Return the mount point to use for images
distro_get_img_mount_point()
{
    echo "${MOUNTDIR}"
}

# Prepare base for installation
distro_prepare_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_prepare_base: \$base is unspecified"
    [ -d "${base}" ] || error "distro_prepare_base: ${base} is invalid"
    mkdir -p "${base}/etc/yum.repos.d"
    [ -d "${base}/etc/yum.repos.d" ] || \
        error "distro_prepare_base: ${base}/etc/yum.repos.d does not exist"
    # Prepare for yum installation
    if [ "i386" = "${AMI_ARCH}" ]; then
        # Force i386 installation because the host may be x86_64
        EXCLUDE="--exclude '*.x86_64'"
        ${SUDO} mkdir -p "${base}/etc/rpm"
        [ -d "${base}/etc/rpm" ] || \
            error "distro_prepare_base: ${base}/etc/rpm does not exist"
        ${SUDO} sh -c "echo \"i686-memes-linux-gnu\" >> \"${base}/etc/rpm/platform\""
        [ -s "${base}/etc/rpm/platform" ] || \
            error "distro_prepare_base: ${base}/etc/rpm/platform is missing or empty"
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
    ${SUDO} sh -c "cat > \"${base}/etc/yum.repos.d/memes.repo\"" <<EOF
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
    ${SUDO} yum -c /tmp/yum.conf -y --installroot="${base}" ${EXCLUDE} \
        --disablerepo="*" --enablerepo="memes*" install ${ROOT_PKGS}
    ${SUDO} rm -rf "${base}/root/.rpmdb"
}


# The install above may have used different db version for RPM, so reinstall
# everything in the chroot to make sure the environment is configured correctly
distro_prepare_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_prepare_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "distro_prepare_chroot: ${base} is invalid"
    ${SUDO} chroot "${base}" <<EOF
# Recreate required devices
/sbin/MAKEDEV -a mem null port zero core full ram tty console random urandom

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

# Enable networking
cat > /etc/sysconfig/network <<eof
NETWORKING=yes
HOSTNAME=localhost.localdomain
NOZEROCONF=yes
NETWORKING_IPV6=no
IPV6_INIT=no
IPV6_ROUTER=no
IPV6_AUTOCONF=no
IPV6FORWARDING=no
IPV6TO4INIT=no
IPV6_CONTROL_RADVD=no
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
127.0.0.1       localhost localhost.localdomain
eof

# Update sudoers file
cat >> /etc/sudoers <<eof
# memes password is random, so don't prompt for sudo
memes ALL=(ALL) NOPASSWD:ALL
eof

# Configure authentication
authconfig --enablemd5 --enableshadow --updateall

# Install the extra packages
[ -n "${EXTRA_PKGS}" ] && yum -y ${EXCLUDE} install ${EXTRA_PKGS}

# Configure SELinux for permissive mode, if config file is present
# This allows future use of SElinux, but doesn't enforce current rules
[ -s /etc/selinux/config ] && \
    sed -i '/^SELINUX=/cSELINUX=permissive' /etc/selinux/config

# Make sure rsyslog, networking and email services are enabled
chkconfig --level 2345 rsyslog on
chkconfig --level 2345 network on
chkconfig --level 2345 postfix on
# Don't need the runtime management of network and services
chkconfig --level 2345 NetworkManager off
chkconfig --level 2345 avahi-daemon off
chkconfig --level 2345 firstboot off

# Change root password to consistent value across instances, but
# remote login is permitted only by public SSH key
echo "${ROOT_PASSWORD}" | passwd --stdin root
mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys2
chmod 0700 /root/.ssh
chmod 0600 /root/.ssh/authorized_keys2
chown -R root:root /root/.ssh

# Add memes with random password
useradd -c "Matthew Emes" -m memes
echo "${MEMES_PASSWORD}" | passwd --stdin memes
mkdir -p /home/memes/.ssh
touch /home/memes/.ssh/authorized_keys2
chmod 0700 /home/memes/.ssh
chmod 0600 /home/memes/.ssh/authorized_keys2
chown -R memes:memes /home/memes/.ssh
EOF
}

# Finalise the chroot installation
distro_post_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_prepare_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "distro_prepare_chroot: ${base} is invalid"
    if [ -e "${SCRIPT_DIR}/ami_sysv" ]; then
	${SUDO} cp "${SCRIPT_DIR}/ami_sysv" "${base}/etc/init.d/ami_sysv"
	${SUDO} chroot "${base}" <<EOF
# Add a SysV init script to configure the instance at boot
if [ -s /etc/init.d/ami_sysv ]; then
    cat > /etc/sysconfig/ami_sysv <<eof
# Owner of AMI instances is memes@matthewemes.com
AMI_OWNER=memes@matthewemes.com
AMI_CC_LIST=
eof
    chmod 0755 /etc/init.d/ami_sysv
    chown root:root /etc/init.d/ami_sysv
    chkconfig --add ami_sysv
fi
EOF
    fi
}

# Clean up
distro_post_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_post_base: \$base is unspecified"
    [ -d "${base}" ] || error "distro_post_base: ${base} is invalid"
    ${SUDO} rm -f "${base}/root/.*history"
    [ -e "${base}/etc/rpm/platform" ] && \
        grep -q memes "${base}/etc/rpm/platform" >/dev/null 2>/dev/null && \
        ${SUDO} rm -f "${base}/etc/rpm/platform"
    [ -e "${base}/etc/rpm/platform" ] && \
        grep -q memes "${base}/etc/rpm/platform" >/dev/null 2>/dev/null && \
        error "distro_post_base: ${base}/etc/rpm/platform still exists"
    return 0
}

# Return a filename for the AMI image
distro_get_ami_img_name()
{
    echo "${WORKINGDIR}/centos_${CENTOS_VER}_${AMI_ARCH}.ami.img"
}

# Return a name for the AMI
distro_get_ami_name()
{
    echo "centos_${CENTOS_VER}_${AMI_ARCH}.$(date +%Y%m%d)"
}

# Return a description for the AMI
distro_get_ami_description()
{
    echo "CentOS ${CENTOS_VER} ${AMI_ARCH} image build of $(date '+%H:%M %Z %m/%d/%y')"
}

# Return a filename for the KVM image
distro_get_kvm_img_name()
{
    echo "${WORKINGDIR}/centos_${CENTOS_VER}_${AMI_ARCH}.kvm.img"
}

# Prepare the kvm filesystem image by installing a kernel
distro_post_kvm_image()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_post_kvm_image: \$base is unspecified"
    [ -d "${base}" ] || error "distro_post_kvm_image: ${base} is invalid"
    ${SUDO} mount --bind /proc "${base}/proc" || \
        error "distro_post_kvm_image: unable to rebind /proc to ${base}/proc"
    ${SUDO} mount --bind /sys "${base}/sys" || \
        error "distro_post_kvm_image: unable to rebind /sys to ${base}/sys"
    # Install a kernel for testing
    ${SUDO} chroot "${base}" yum -y ${EXCLUDE} install kernel
    ${SUDO} umount "${base}/sys" || \
        error "distro_post_kvm_image: unable to umount ${base}/sys"
    ${SUDO} umount "${base}/proc" || \
        error "distro_post_kvm_image: unable to umount ${base}/proc"
}