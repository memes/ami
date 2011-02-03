# Bootstrap an AMI builder instance customisation file for MEmes AMI builder
#
# This file is sourced before building begins and can modify
# environment variables and provide customisation functions for
# various stages.
#
# Custom functions should be able to use any builder functions

WORKINGDIR=${WORKINGDIR:-"$(pwd)"}
EXTRA_PKGS="debootstrap yum"

# Force Debian as the distro
distro=debian

# Return the directory to use for base install
custom_get_base_directory()
{
    echo "${WORKINGDIR}/ami_builder_${AMI_ARCH}"
}

# Return the mount point to use for images
custom_get_img_mount_point()
{
    echo "${WORKINGDIR}/ami_builder_${AMI_ARCH}.mnt"
}

# customise the chroot install before creating an image
custom_post_chroot()
{
    # Expect to be passed the base dir in arg 1
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "custom_post_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "custom_post_chroot: ${base} is invalid"
    ${SUDO} rsync -avP --exclude '*~' /home/memes/aws "${base}/home/memes/"
    ${SUDO} chroot "${base}" <<EOF
[ -e /home/memes/aws ] && sudo chown -R memes:memes /home/memes/aws
cat >> /home/memes/.bashrc <<eof

# Include AWS settings, if present
[ -s /home/memes/aws/aws.rc ] && . /home/memes/aws/aws.rc

# Default to creation of AMI images in specific directory
export DEFAULT_MINIMAL_WORKING_DIRECTORY=/home/memes/images
export WORKINGDIR=/home/memes/images

# Default to lenny releases for Debian AMIs
export DEBIAN_VER=lenny
eof
cat > /home/memes/.gitconfig <<eof
[user]
	name = Matthew Emes
	email = memes@matthewemes.com
eof
[ -d /home/memes/ami ] || \
    git clone http://scm.matthewemes.com/ami.git /home/memes/ami
cd /home/memes/ami && git pull
[ -d /home/memes/images ] || mkdir -p /home/memes/images
update-rc.d -f yum-updatesd remove

# Install java
echo "sun-java6-jdk shared/accepted-sun-dlj-v1-1 boolean true" | debconf-set-selections
apt-get clean
apt-get update
apt-get install -y --no-install-recommends sun-java6-jdk
EOF
    local uid=$(awk -F: '/^memes/ {print $3}' "${base}/etc/passwd")
    local gid=$(awk -F: '/^memes/ {print $4}' "${base}/etc/passwd")
    ${SUDO} chown -R ${uid}:${gid} "${base}/home/memes"
}

# Return a filename for the AMI image
custom_get_ami_img_name()
{
    echo "${WORKINGDIR}/ami_builder_${AMI_ARCH}.ami.img"
}

# Return a file size for the AMI image
custom_get_ami_img_size()
{
    # 2Gb should be enough
    echo $((1024 * 1024 * 1024 * 2))
}

# Return a name for the AMI
custom_get_ami_name()
{
    echo "ami_builder_${AMI_ARCH}.$(date +%Y%m%d)"
}

# Return a description for the AMI
custom_get_ami_description()
{
    echo "MEmes AMI Builder ${AMI_ARCH} image build of $(date '+%H:%M %Z %m/%d/%y')"
}

# Return a filename for the KVM image
custom_get_kvm_img_name()
{
    echo "${WORKINGDIR}/ami_builder_${AMI_ARCH}.kvm.img"
}

# Return a file size for the KVM image
custom_get_kvm_img_size()
{
    # 2Gb should be enough
    echo $((1024 * 1024 * 1024 * 2))
}
