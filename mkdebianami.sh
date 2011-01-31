#! /bin/sh
#
# Simple shell script to create a Debian image suitable for EC2
# deployment
#
# $Id: $

[ "x86_64" = "${AMI_ARCH}" ] && DEBIAN_ARCH="amd64"
[ -z "${DEBIAN_ARCH}" ] && DEBIAN_ARCH="${AMI_ARCH}"

DEBIAN_VER=${DEBIAN_VER:-stable}
MIRROR_URL=${MIRROR_URL:-"http://ftp.debian.org"}
WORKINGDIR=${WORKINGDIR:-"$(pwd)"}
MOUNTDIR=${MOUNTDIR:-"$(pwd)/debian_${DEBIAN_VER}_${DEBIAN_ARCH}.mnt"}
ROOT_PKGS=${ROOT_PKGS:-"locales less bzip2"}
BASE_PKGS=${BASE_PKGS:-"vim sudo openssh-server git-core subversion mercurial s3cmd"}
EXTRA_PKGS=${EXTRA_PKGS:-""}

# Return the directory to use for base install
distro_get_base_directory()
{
    echo "${WORKINGDIR}/debian_${DEBIAN_VER}_${DEBIAN_ARCH}"
}

# Return the mount point to use for images
distro_get_img_mount_point()
{
    echo "${MOUNTDIR}"
}

# Install minimum set of packages in order to get functional system
distro_prepare_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_prepare_base: \$base is unspecified"
    [ -d "${base}" ] || error "distro_prepare_base: ${base} is invalid"
    ${SUDO} debootstrap --arch ${DEBIAN_ARCH} \
        ${ROOT_PKGS:+"--include=$(echo ${ROOT_PKGS} | tr ' ' ',')"} \
        ${DEBIAN_VER} ${base} || \
        error "distro_prepare_base: debootstrap failed: error code $?"
}

# Populate the chroot; /proc, /sys, etc are already mounted
distro_prepare_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_prepare_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "distro_prepare_chroot: ${base} is invalid"
    ${SUDO} chroot "${base}" <<EOF
# Recreate required devices
/sbin/MAKEDEV -d mem null zero ram tty console random urandom

# Disable daemon startup during chroot population
echo "exit 101" > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
echo "America/Los_Angeles" > /etc/timezone

LC_ALL=C debconf-set-selections <<eof
tzdata  tzdata/Zones/America select Los_Angeles
locales locales/default_environment_locale select en_US.UTF-8
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
eof
LC_ALL=C dpkg-reconfigure --frontend noninteractive --all
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
LC_ALL=C locale-gen

# Add security to the APT sources 
cat >> /etc/apt/sources.list <<eof
deb http://security.debian.org stable/updates main
eof
apt-get update

# Disable TLS when running under xen
cat >> /etc/ld.so.conf.d/xen.conf <<eof
# Disable TLS when the image is running under xen
hwcap 0 nosegneg
eof
ldconfig

# Set the timezone for the instance shells
cat >> /etc/profile.d/timezone.sh <<eof
TZ=America/Los_Angeles
export TZ
eof
cat >> /etc/profile.d/timezone.csh <<eof
setenv TZ America/Los_Angeles
eof

# Enable networking
echo "localhost" > /etc/hostname
cat > /etc/sysctl.d/no_ip6.conf <<eof
# Disable IPv6
net.ipv6.conf.all.disable_ipv6=1
eof
cat > /etc/network/interfaces <<eof
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
eof
cat > /etc/hosts <<eof
127.0.0.1       localhost localhost.localdomain
eof

# Update sudoers file
cat >> /etc/sudoers <<eof
# memes password is random, so don't prompt for sudo
memes ALL=(ALL) NOPASSWD:ALL
eof

# Install any remaining base packages or extra packages
[ -n "${BASE_PKGS}" -o "${EXTRA_PKGS}" ] && \
    apt-get install -y ${BASE_PKGS} ${EXTRA_PKGS}

# Change root password to consistent value across instances, but
# remote login is permitted only by public SSH key
mkdir -p /root/.ssh
touch /root/.ssh/authorized_keys2
chmod 0700 /root/.ssh
chmod 0600 /root/.ssh/authorized_keys2
chown -R root:root /root/.ssh

# Add memes with random password
useradd -c "Matthew Emes" -m memes
mkdir -p /home/memes/.ssh
touch /home/memes/.ssh/authorized_keys2
chmod 0700 /home/memes/.ssh
chmod 0600 /home/memes/.ssh/authorized_keys2
chown -R memes:memes /home/memes/.ssh
chpasswd <<eof
root:${ROOT_PASSWORD}
memes:${MEMES_PASSWORD}
eof

# Clean up apt database
apt-get clean
EOF
}

# Finalise the chroot actions
distro_post_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_post_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "distro_post_chroot: ${base} is invalid"
    if [ -e "${SCRIPT_DIR}/ami_sysv" ]; then
	${SUDO} cp "${SCRIPT_DIR}/ami_sysv" "${base}/etc/init.d/ami_sysv"
	${SUDO} chroot "${base}" <<EOF
# Add a SysV init script to configure the instance at boot
if [ -s /etc/init.d/ami_sysv ]; then
    cat > /etc/default/ami_sysv <<eof
# Owner of AMI instances is memes@matthewemes.com
AMI_OWNER=memes@matthewemes.com
AMI_CC_LIST=
eof
    chmod 0755 /etc/init.d/ami_sysv
    chown root:root /etc/init.d/ami_sysv
    update-rc.d ami_sysv defaults
fi
EOF
    fi
}
# Clean up after installation
distro_post_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "distro_post_base: \$base is unspecified"
    [ -d "${base}" ] || error "distro_post_base: ${base} is invalid"
    ${SUDO} rm -f "${base}/root/.*history" "${base}/usr/sbin/policy-rc.d" || \
        warn "distro_post_base: error code $? returned while deleting files"
    return 0
}

# Return a filename for the AMI image
distro_get_ami_img_name()
{
    echo "${WORKINGDIR}/debian_${DEBIAN_VER}_${DEBIAN_ARCH}.ami.img"
}

# Return a name for the AMI
distro_get_ami_name()
{
    echo "debian_${DEBIAN_VER}_${DEBIAN_ARCH}.$(date +%Y%m%d)"
}

# Return a description for the AMI
distro_get_ami_description()
{
    echo "Debian ${DEBIAN_VER} ${DEBIAN_ARCH} image build of $(date '+%H:%M %Z %m/%d/%y')"
}

# Return a filename for the KVM image
distro_get_kvm_img_name()
{
    echo "${WORKINGDIR}/debian_${DEBIAN_VER}_${DEBIAN_ARCH}.kvm.img"
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
    local kernel_flavour=
    [ "i386" = "${DEBIAN_ARCH}" ] && kernel_flavour=686
    [ -z "${kernel_flavour}" ] && kernel_flavour=${DEBIAN_ARCH}
    ${SUDO} chroot "${base}" <<EOF
cat > /etc/kernel-img.conf <<eof
do_symlinks = no
relative_links = yes
do_bootloader = no
do_bootfloppy = no
do_initrd = yes
link_in_boot = no
eof
apt-get install -y linux-image-${kernel_flavour}
rm -f /etc/udev/rules.d/70-persistent-net.rules
EOF
    ${SUDO} umount "${base}/sys" || \
        error "distro_post_kvm_image: unable to umount ${base}/sys"
    ${SUDO} umount "${base}/proc" || \
        error "distro_post_kvm_image: unable to umount ${base}/proc"
}