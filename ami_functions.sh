# Common functions for creating AMI images
#
# Environment variables used:-
#  AMI_ARCH the architecture of the AMI; i386 or x86_64
#  img_dev the loop device that contains the full disk image
#  part_dev the loop device that contains the filesystem image
# Environment variables used if present:-
#  AMI_TMP temporary file locations for bundling
#  AMI_PART number of the part to begin uploading, normally unspecified
#  AMI_LOCATION an optional bucket location to specify when creating new bucket
#  AMI_URL S3 service url, tools use an appropriate value for US when unspecifed
#  AMI_RETRY number of retry attempts for online actions
#  AMI_SKIPMANIFEST do not upload the manifest file

# Default constant values
DEFAULT_IMG_SIZE=${DEFAULT_IMG_SIZE:-$((1024 * 1024 * 1024))}
DEFAULT_IMG_HEADS=${DEFAULT_IMG_HEADS:-255}
DEFAULT_IMG_SECTORS=${DEFAULT_IMG_SECTORS:-63}
DEFAULT_IMG_SECTOR_SIZE=${DEFAULT_IMG_SECTOR_SIZE:-512}
DEFAULT_FS_BLOCK_SIZE=${DEFAULT_FS_BLOCK_SIZE:-4096}
DEFAULT_AMI_TMP=${DEFAULT_AMI_TMP:-~/tmp}
DEFAULT_MINIMAL_WORKING_DIR=${DEFAULT_MINIMAL_WORKING_DIR:-~/}
DEFAULT_KVM_MEM=${DEFAULT_KVM_MEM:-2048}
DEFAULT_KVM_NET=${DEFAULT_KVM_NET:-virtio}

# Store modified fs mounts for dev/nodev
nodev_mounts=""

# Store ip_forward value for cleanup
IPV4_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward)

# Util to send a message to stderr and exit
error()
{
    echo "$0: Error: $*" >&2
    exit 1
}

# Util to send a message to stderr but do not exit
warn()
{
    echo "$0: Warning: $*" >&2
}

# Don't be stupid - too late!
# $1 = path to test, $2, if present, suppresses check for existence of path
dont_be_stupid()
{
    local path=
    [ $# -ge 1 ] && path="$1"
    [ -z "${path}" ] && \
        error "dont_be_stupid: \$path is empty, are you sure you know where this is going to go?"
    [ -e "${path}" ] || \
        error "dont_be_stupid: path ${path} does not exist, this could be trouble"
    local sanity_check=$(echo "${path}" | tr -cd '[:alnum:]/._' 2>/dev/null)
    [ "${sanity_check}" = "${path}" ] || \
        error "dont_be_stupid: path ${path} contains disallowed characters"
    local canonical=$(readlink -f "${path}" 2>/dev/null)
    [ -z "${canonical}" ] && \
	error "dont_be_stupid: canonical path is empty"
    [ "/" = "${canonical}" ] && \
        error "dont_be_stupid: not allowed to do anything in root"
    [ -d "${canonical}" ] || canonical=$(dirname "${canonical}")
    [ -d "${canonical}" ] || \
        error "dont_be_stupid: parent directory of ${path} does not exist"
    [ "/" = "${canonical}" ] && \
        error "dont_be_stupid: not allowed to do anything in root"
    local base_working_dir=$(readlink -f ${AMI_WORKING_DIR:-${DEFAULT_MINIMAL_WORKING_DIR}} 2>/dev/null)
    echo "${canonical}" | grep -q "^${base_working_dir}" >/dev/null 2>/dev/null
    [ $? -ne 0 ] && \
        error "path [${path}] is outside the base working directory [${AMI_WORKING_DIR:-${DEFAULT_MINIMAL_WORKING_DIR}}]"
}

# Return 0 (success) if the path in $1 is mounted
ismounted()
{
    [ -z "$1" ] && return 1;
    grep -q "$1" /proc/mounts >/dev/null 2>/dev/null
    return $?
}

# Return 0 (success) if the device in $1 is active loop dev
isloop()
{
    [ -z "$1" ] && return 1;
    ${SUDO} losetup -a 2>/dev/null | grep -q "$1" >/dev/null 2>/dev/null
    return $?
}

# Get the mount point for the file $1
get_mountpoint()
{
    local mnt=
    local file=
    [ $# -ge 1 ] && file="$1"
    [ -z "${file}" ] && warn "get_mountpoint: \$file is empty"
    [ -z "${file}" ] && return
    file=$(readlink -f "${file}" 2>/dev/null)
    [ -e "${file}" ] || warn "get_mountpoint: ${file} is not a valid"
    [ -e "${file}" ] || return
    local dev=
    local mnt_point=
    local other=
    local fit_weighting=99999
    local tmp=
    while read dev mnt_point other; do
        tmp=${file##$mnt_point}
        [ -z "${tmp}" ] && continue
        if [ ${#tmp} -lt ${fit_weighting} ]; then
            mnt="${mnt_point}"
            fit_weighting=${#tmp}
        fi
    done < /proc/mounts
    echo "${mnt}"
}

# Make the mount point for $1 be dev enabled
enable_dev_files_for()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "enable_dev_files_for: \$base is unsepcified"
    local mnt=$(get_mountpoint "${base}")
    [ -z "${mnt}" ] && \
        error "enable_dev_files_for: no mount point found for ${base}"
    grep -q " ${mnt} .*nodev" /proc/mounts >/dev/null 2>/dev/null
    if [ $? -eq 0 ]; then
        # Add this mount point to list of modified mount points, if not already
        # accounted for
        echo "${nodev_mounts}" | grep -q ":${mnt}:" >/dev/null 2>/dev/null || \
            nodev_mounts="${nodev_mounts}:${mnt}:"
        ${SUDO} mount -o remount,dev "${mnt}"
    fi
    grep -q " ${mnt} .*nodev" /proc/mounts >/dev/null 2>/dev/null && \
        error "enable_dev_files_for: ${mnt} is not mounted with dev support"
}

# Make the mount point for $1 be dev disabled
# Note: cannot use error since exiting may trigger cleanup which uses this
# function
disable_dev_files_for()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && warn "disable_dev_files_for: \$base is unsepcified" && \
        return
    [ -e "${base}" ] || return
    local mnt=$(get_mountpoint "${base}")
    [ -z "${mnt}" ] && \
        warn "disable_dev_files_for: no mount point found for ${base}" && \
        return
    grep -q " ${mnt} .*nodev" /proc/mounts >/dev/null 2>/dev/null
    if [ $? -ne 0 ]; then
    # Check the nodev_mounts to see if the script made this mount point
    # support devices where previously it was disabled and remount only then
        echo "${nodev_mounts}" | grep -q ":${mnt}:" >/dev/null 2>/dev/null
        if [ $? -eq 0 ]; then
            # This mount was remounted with dev support by this script, allow
            # remount
            local sanitised_mnt=$(echo "${mnt}" | sed -e's/\//\\\//g')
            nodev_mounts=$(echo "${nodev_mounts}" | sed -e"s/:${sanitised_mnt}://g")
            ${SUDO} mount -o remount,nodev "${mnt}"
            grep -q " ${mnt} .*nodev" /proc/mounts >/dev/null 2>/dev/null || \
                warn "disable_dev_files_for: ${mnt} is still mounted with dev support"
        fi
    fi
}

# Clean up any resources remaining from build
cleanup ()
{
    for dir in "${base_dir}" "${mount_point}"
    do
        [ -z "${dir}" ] && continue
        disable_dev_files_for "${dir}"
        [ -n "${dir}" ] && ismounted "${dir}/proc" && \
            ${SUDO} umount "${dir}/proc"
        [ -n "${dir}" ] && ismounted "${dir}/sys" && \
            ${SUDO} umount "${dir}/sys"
        [ -n "${dir}" ] && ismounted "${dir}" && \
            grep "${dir}" /proc/mounts 2>/dev/null | grep -q "/dev/loop" >/dev/null 2>/dev/null && \
            ${SUDO} umount "${dir}"
    done
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
        ${SUDO} losetup -d "${part_dev}"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
        ${SUDO} losetup -d "${img_dev}"
    local ipv4_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    [ ${IPV4_FORWARD} -eq ${ipv4_forward} ] || \
	${SUDO} sh -c "echo ${IPV4_FORWARD} > /proc/sys/net/ipv4/ip_forward"
}



# Handle distro specifics before building starts
prebuild_distro()
{
    local script_dir=
    local distro=
    [ $# -ge 1 ] && script_dir="$1"
    [ $# -ge 2 ] && distro="$2"
    [ -z "${script_dir}" ] && \
        error "prebuild_distro: \$script_dir is unspecified"
    [ -d "${script_dir}" ] || \
        error "prebuild_distro: ${script_dir} is invalid"
    [ -z "${distro}" ] && \
        error "prebuild_distro: \$distro is unspecified"
    local distro_file="$(readlink -f ${script_dir}/distro_${distro} 2>/dev/null)"
    [ -z "${distro_file}" -o ! -r "${distro_file}" ] && \
        distro_file="$(readlink -f ${script_dir}/distro_${distro}.sh 2>/dev/null)"
    [ -z "${distro_file}" -o ! -r "${distro_file}" ] && \
        distro_file="$(readlink -f ${script_dir}/distro_{distro}.rc 2>/dev/null)"
    [ -z "${distro_file}" -o ! -r "${distro_file}" ] && \
        distro_file="$(readlink -f ${script_dir}/distro_{distro}rc 2>/dev/null)"
    [ -z "${distro_file}" -o ! -r "${distro_file}" ] && \
        error "prebuild_distro: cannot find a script for ${distro}"
    . "${distro_file}"
}

# Handle customisation before building starts
prebuild_custom()
{
    local script_dir=
    local custom=
    [ $# -ge 1 ] && script_dir="$1"
    [ $# -ge 2 ] && custom="$2"
    [ -z "${script_dir}" ] && \
        error "prebuild_custom: \$script_dir is unspecified"
    [ -d "${script_dir}" ] || \
        error "prebuild_custom: ${script_dir} is invalid"
    [ -z "${custom}" ] && \
        error "prebuild_custom: \$custom is unspecified"
    local custom_file="$(readlink -f ${script_dir}/custom_${custom} 2>/dev/null)"
    [ -z "${custom_file}" -o ! -r "${custom_file}" ] && \
        custom_file="$(readlink -f ${script_dir}/custom_${custom}.sh 2>/dev/null)"
    [ -z "${custom_file}" -o ! -r "${custom_file}" ] && \
        custom_file="$(readlink -f ${script_dir}/custom_{custom}.rc 2>/dev/null)"
    [ -z "${custom_file}" -o ! -r "${custom_file}" ] && \
        custom_file="$(readlink -f ${script_dir}/custom_{custom}rc 2>/dev/null)"
    [ -z "${custom_file}" -o ! -r "${custom_file}" ] && \
        error "prebuild_custom: cannot find a script for ${custom}"
    . "${custom_file}"
}

# Handle flavour specifications before building starts
prebuild_flavour()
{
    local script_dir=
    local flavour=
    [ $# -ge 1 ] && script_dir="$1"
    [ $# -ge 2 ] && flavour="$2"
    [ -z "${script_dir}" ] && \
        error "prebuild_flavour: \$script_dir is unspecified"
    [ -d "${script_dir}" ] || \
        error "prebuild_flavour: ${script_dir} is invalid"
    [ -z "${flavour}" ] && \
        error "prebuild_flavour: \$flavour is unspecified"
    local flavour_file="$(readlink -f ${script_dir}/flavour_${flavour} 2>/dev/null)"
    [ -z "${flavour_file}" -o ! -r "${flavour_file}" ] && \
        flavour_file="$(readlink -f ${script_dir}/flavour_${flavour}.sh 2>/dev/null)"
    [ -z "${flavour_file}" -o ! -r "${flavour_file}" ] && \
        flavour_file="$(readlink -f ${script_dir}/flavour_{flavour}.rc 2>/dev/null)"
    [ -z "${flavour_file}" -o ! -r "${flavour_file}" ] && \
        flavour_file="$(readlink -f ${script_dir}/flavour_{flavour}rc 2>/dev/null)"
    [ -z "${flavour_file}" -o ! -r "${flavour_file}" ] && \
        error "prebuild_flavour: cannot find a script for ${flavour}"
    . "${flavour_file}"
}

# Execute a distro specifc implementation of stage $1, passing all other
# arguments
distro_stage()
{
    local stage=
    [ $# -ge 1 ] && stage="$1"
    [ -z "${stage}" ] && error "distro_stage: \$stage is unspecified"
    eval "type distro_${stage} >/dev/null 2>/dev/null" || return
    shift
    eval "distro_${stage} $@" || \
        error "distro_stage: ${stage}: distro function returned error code $?"
}

# Execute a customisation of stage $1, passing all other arguments
custom_stage()
{
    local stage=
    [ $# -ge 1 ] && stage="$1"
    [ -z "${stage}" ] && error "custom_stage: \$stage is unspecified"
    eval "type custom_${stage} >/dev/null 2>/dev/null" || return
    shift
    eval "custom_${stage} $@" || \
        error "custom_stage: ${stage}: custom function returned error code $?"
}

# Execute a flavour specifc implementation of stage $1, passing all other
# arguments
flavour_stage()
{
    local stage=
    [ $# -ge 1 ] && stage="$1"
    [ -z "${stage}" ] && error "flavour_stage: \$stage is unspecified"
    eval "type flavour_${stage} >/dev/null 2>/dev/null" || return
    shift
    eval "flavour_${stage} $@" || \
        error "flavour_stage: ${stage}: flavour function returned error code $?"
}

# Validate the environment is ready for use
prebuild_validate()
{
    flavour_stage prebuild_validate
    distro_stage prebuild_validate
    custom_stage prebuild_validate
    [ -z "${SUDO}" ] && \
        error "prebuild_validate: \${SUDO} is not specified"
    [ -x "${SUDO}" ] || \
        error "prebuild_validate: \$SUDO [${SUDO}] is invalid"
    [ -z "${AMI_ARCH}" ] && \
        error "prebuild_validate: AMI architecture must be specified in \$AMI_ARCH"
    [ "i386" = "${AMI_ARCH}" -o "x86_64" = "${AMI_ARCH}" ] || \
        error "prebuild_validate: AMI architecture must be i386 or x86_64: ${AMI_ARCH} is invalid"
    [ "x86_64" = "${AMI_ARCH}" -a "x86_64" != "$(uname -m)" ] && \
        error "prebuild_validate: cannot build ${AMI_ARCH} install on $(uname -m) host"
    [ -z "${WORKINGDIR}" ] && \
	error "prebuild_validate: working directory must be specified in \$WORKINGDIR"
    [ -d "${WORKINGDIR}" -a -w "${WORKINGDIR}" ] || \
	error "prebuild_validate: working directory $WORKINGDIR is invalid"
}

# Prepare the base before the chroot happens; just a place-holder for distro and
# custom hooks
prepare_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "prepare_base: \$base is unspecified"
    dont_be_stupid "${base}"
    enable_dev_files_for "${base}"
    flavour_stage prepare_base "${base}"
    distro_stage prepare_base "${base}"
    custom_stage prepare_base "${base}"
}

# Prepare to chroot to $1
prepare_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "prepare_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "prepare_chroot: directory ${base} is invalid"
    enable_dev_files_for "${base}"
    dont_be_stupid "${base}"
    ${SUDO} mkdir -p "${base}/proc" "${base}/sys"
    [ -d "${base}/proc" ] || error "prepare_chroot: ${base}/proc does not exist"
    [ -d "${base}/sys" ] || error "prepare_chroot: ${base}/sys does not exist"
    ismounted "${base}/proc" || ${SUDO} mount --bind /proc "${base}/proc"
    ismounted "${base}/proc" || \
        error "prepare_chroot: ${base}/proc is not mounted"
    ismounted "${base}/sys" || ${SUDO} mount --bind /sys "${base}/sys"
    ismounted "${base}/sys" || \
        error "prepare_chroot: ${base}/sys is not mounted"
    flavour_stage prepare_chroot "${base}"
    distro_stage prepare_chroot "${base}"
    custom_stage prepare_chroot "${base}"
}

# Execute any customisation scripts and remove chroot specific mounts in $1
post_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "post_chroot: \$base is unspecified"
    dont_be_stupid "${base}"
    flavour_stage post_chroot "${base}"
    distro_stage post_chroot "${base}"
    custom_stage post_chroot "${base}"
    disable_dev_files_for "${base}"
    ismounted "${base}/proc" && ${SUDO} umount "${base}/proc"
    ismounted "${base}/sys" && ${SUDO} umount "${base}/sys"
    ismounted "${base}/proc" && \
        error "post_chroot: ${base}/proc is still mounted"
    ismounted "${base}/sys" && error "post_chroot: ${base}/sys is still mounted"
}

# Finalise the base before further actions; just a place-holder for distro and
# custom hooks
post_base()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "post_base: \$base is unspecified"
    dont_be_stupid "${base}"
    # Add a record of this build
    ${SUDO} sh -c "cat > ${base}/etc/ami_builder" <<EOF
AMI instance built on host $(hostname --fqdn)  at $(date '+%H:%M %Z on %m/%d/%y')
  Invocation parameters: $(cat /proc/$$/cmdline | tr '\0' ' ')
  Working directory: $(readlink -f /proc/$$/cwd 2>/dev/null)
EOF
    flavour_stage post_base "${base}"
    distro_stage post_base "${base}"
    custom_stage post_base "${base}"
}

# Clean up an existing chroot at $1
rm_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "rm_chroot: \$base is unspecified"
    [ -d "${base}" ] || return
    dont_be_stupid "${base}"
    flavour_stage rm_chroot "${base}"
    distro_stage rm_chroot "${base}"
    custom_stage rm_chroot "${base}"
    disable_dev_files_for "${base}"
    ismounted "${base}/proc" && ${SUDO} umount "${base}/proc"
    ismounted "${base}/sys" && ${SUDO} umount "${base}/sys"
    ismounted "${base}/proc" && \
        error "rm_chroot: ${base}/proc is still mounted"
    ismounted "${base}/sys" && error "rm_chroot: ${base}/sys is still mounted"
    [ -d "${base}" ] && ${SUDO} rm -rf "${base}"
    [ -d "${base}" ] && error "rm_chroot: ${base} still exists"
}

# mount an image on $part_dev at $1
mount_img()
{
    local mnt=
    [ $# -ge 1 ] && mnt="$1"
    [ -z "${mnt}" ] && error "mount_img: \$mnt is unspecified"
    dont_be_stupid "$(dirname ${mnt})"
    flavour_stage mount_image "${mnt}"
    distro_stage mount_image "${mnt}"
    custom_stage mount_image "${mnt}"
    [ -d "${mnt}" ] || mkdir -p "${mnt}"
    [ -d "${mnt}" ] || error "mount_img: directory ${mnt} does not exist"
    [ -d "${mnt}/proc" ] && ismounted "${mnt}/proc" && ${SUDO} umount "${mnt}/proc"
    ismounted "${mnt}/proc" && error "mount_img: ${mnt}/proc is still mounted"
    [ -d "${mnt}/sys" ] && ismounted "${mnt}/sys" && ${SUDO} umount "${mnt}/sys"
    ismounted "${mnt}/sys" && error "mount_img: ${mnt}/sys is still mounted"
    ismounted "${mnt}" && ${SUDO} umount "${mnt}"
    ismounted "${mnt}" && \
        error "mount_img: ${mnt} is still mounted from previous activity"
    [ -z "${part_dev}" ] && error "mount_img: mount device is unspecified"
    [ -b "${part_dev}" ] || error "mount_img: ${part_dev} is not a block device"
    ${SUDO} mount ${part_dev} "${mnt}" || \
        error "mount_img: unable to mount ${part_dev} at ${mnt}: returned error code $?"
}

# unmount the image $1 and release loop devices
umount_img()
{
    local mnt=
    [ $# -ge 1 ] && mnt="$1"
    [ -z "${mnt}" ] && error "umount_img: \$mnt is unspecified"
    dont_be_stupid "${mnt}"
    flavour_stage umount_image "${mnt}"
    distro_stage umount_image "${mnt}"
    custom_stage umount_image "${mnt}"
    ismounted "${mnt}" && ${SUDO} umount "${mnt}"
    ismounted "${mnt}" && error "umount_img: ${mnt} is still mounted"
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
        ${SUDO} losetup -d "${part_dev}"
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
        error "umount_img: ${part_dev} is still a loop device"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
        ${SUDO} losetup -d "${img_dev}"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
        error "umount_img: ${img_dev} is still a loop device"
}

# Create an fstab file for the instance at $1
update_fstab()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "update_fstab: \$base is unspecified"
    dont_be_stupid "${base}"
    [ -d "${base}/etc" ] || \
        error "update_fstab: ${base}/etc does not exist"
    ${SUDO} sh -c "cat > \"${base}/etc/fstab\"" <<EOF
LABEL=root      /               ext3        defaults,noatime        0        1
none            /dev/pts        devpts      defaults,gid=5,mode=620 0        0
none            /proc           proc        defaults                0        0
none            /sys            sysfs       defaults                0        0
EOF

    # Debian automounts /dev/shm during boot, but add to fstab for CentOS
    if [ "centos" = "${distro}" ]; then
        ${SUDO} sh -c "cat >> \"${base}/etc/fstab\"" <<EOF
none            /dev/shm        tmpfs       defaults                0        0
EOF
    fi

    # If the kernel is pvgrub then the block devices must be /dev/xvdX instead
    # of /dev/sdX
    local blockdev=/dev/sd
    support_pvgrub && blockdev=/dev/xvd
    if [ "i386" = "${AMI_ARCH}" ]; then
        ${SUDO} sh -c "cat >> \"${base}/etc/fstab\"" <<EOF
# 32 bit (m1.small and c1.medium instances)
${blockdev}a2       /mnt            ext3        defaults,noauto         0        0
${blockdev}a3       swap            swap        defaults                0        0
EOF
    fi

    if [ "x86_64" = "${AMI_ARCH}" ]; then
        ${SUDO} sh -c "cat >> \"${base}/etc/fstab\"" <<EOF
# 64 bit (m1.large, m1.xlarge, c1.xlarge, cc1.4xlarge, cg1.4xlarge,
# m2.xlarge, m2.2xlarge, and m2.4xlarge instances)
${blockdev}b        /mnt            ext3        defaults,noauto         0        0
${blockdev}c        /mnt            ext3        defaults,noauto         0        0
EOF
    fi
    flavour_stage update_fstab "${base}"
    distro_stage update_fstab "${base}"
    custom_stage update_fstab "${base}"
    [ -s "${base}/etc/fstab" ] || \
        error "update_fstab: ${base}/etc/fstab is missing or empty"
}

# Update sshd configuration at $1
update_sshd()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "update_sshd: \$base is unspecified"
    dont_be_stupid "${base}"
    [ -e "${base}/etc/ssh/sshd_config" ] || \
        error "update_sshd: ${base}/etc/ssh/sshd_config does not exist"
    ${SUDO} sed -i -e'/^#\?PermitRootLogin/cPermitRootLogin without-password' -e'/^#\?UseDNS/cUseDNS no' "${base}/etc/ssh/sshd_config"
    ${SUDO} grep -q "^PermitRootLogin without-password" "${base}/etc/ssh/sshd_config" >/dev/null 2>/dev/null || \
        error "update_sshd: ${base}/etc/ssh/sshd_config is not updated"
    flavour_stage update_sshd "${base}"
    distro_stage update_sshd "${base}"
    custom_stage update_sshd "${base}"
}

# Add memes public ssh keys to memes account at $1
# Folder for the keys should have already been created and given correct
# ownership/permissions
add_memes_keys()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "add_memes_keys: \$base is unspecified"
    dont_be_stupid "${base}"
    ${SUDO} sh -c "[ -d \"${base}/home/memes/.ssh\" ] || mkdir -p \"${base}/home/memes/.ssh\""
    if [ -d /media/protected/.ssh ]; then
        for key in /media/protected/.ssh/memes@matthewemes.com*pub
        do
            ${SUDO} sh -c "cat ${key} >> \"${base}/home/memes/.ssh/authorized_keys2\""
        done
    else
        [ -d ~/.ssh/ ] && \
            for key in ~/.ssh/memes@matthewemes.com*pub 
        do
            ${SUDO} sh -c "cat ${key} >> \"${base}/home/memes/.ssh/authorized_keys2\""
        done
    fi
    flavour_stage add_memes_keys "${base}"
    distro_stage add_memes_keys "${base}"
    custom_stage add_memes_keys "${base}"
    
    # Reset permissions on all .ssh files
    local uid=$(awk -F: '/^memes/ {print $3}' "${base}/etc/passwd")
    local gid=$(awk -F: '/^memes/ {print $4}' "${base}/etc/passwd")
    ${SUDO} chown -R ${uid}:${gid} "${base}/home/memes/.ssh"
    ${SUDO} find "${base}/home/memes/.ssh" -type f -exec chmod 0600 {} \;
}

# Update inittab configuration at $1
update_inittab()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "update_inittab: \$base is unspecified"
    dont_be_stupid "${base}"
    [ -e "${base}/etc/inittab" ] || \
        error "update_inittab: ${base}/etc/inittab does not exist"
    ${SUDO} sed -i '/^[2-6]:[2-5]\+:.*getty/ s/^/#/g' "${base}/etc/inittab"
    local test=$(${SUDO} grep -c '^[2-6].*getty' "${base}/etc/inittab" 2>/dev/null)
    if [ "1" = "${test}" ]; then
	# Check to see if ttys are configured elsewhere
	if [ -e "${base}/etc/sysconfig/init" ]; then
	    ${SUDO} sed -i '/^ACTIVE_CONSOLES/cACTIVE_CONSOLES=/dev/tty1' "${base}/etc/sysconfig/init"
	    test=$(${SUDO} grep -c '^ACTIVE_CONSOLES=/dev/tty[^1]' "${base}/etc/sysconfig/init" 2>/dev/null)
	    [ "1" = "${test}" ] && \
		error "update_inittab: ${base}/etc/sysconfig/init is not updated"
	else
            error "update_inittab: ${base}/etc/inittab is not updated"
	fi
    fi
    flavour_stage update_inittab "${base}"
    distro_stage update_inittab "${base}"
    custom_stage update_inittab "${base}"
}

# Make a disk image filename $1 of size $2 and setup block devices to access
# the full disk and the first partition
# Sets the global vars $img_dev and $part_dev
mk_disk_image()
{
    local img=
    local img_size=
    [ $# -ge 1 ] && img="$1"
    [ $# -ge 2 ] && img_size="$2"
    [ -z "${img}" ] && \
        error "mk_disk_image: filename for image must be specified"
    local img_dir=$(dirname "${img}")
    dont_be_stupid "${img_dir}"
    [ -d "${img_dir}" ] || error "mk_disk_image: ${img_dir} does not exist"
    [ -r "${img}" ] && ${SUDO} rm -f "${img}"
    [ -r "${img}" ] && error "mk_disk_image: ${img} already exists"
    flavour_stage mk_disk_image "${img}" "${img_size}"
    distro_stage mk_disk_image "${img}" "${img_size}"
    custom_stage mk_disk_image "${img}" "${img_size}"
    [ ${img_size} -ne ${img_size} >/dev/null 2>/dev/null ]
    if [ $? -ne 1 -a -n "${img_size}" ]; then
        warn "mk_disk_image: image size is not a number: ${img_size}"
        img_size=
    fi
    [ -z "${img_size}" ] && \
        warn "mk_disk_image: image size is unspecified, using default value [${DEFAULT_IMG_SIZE}]"
    [ -z "${img_size}" ] && img_size=${DEFAULT_IMG_SIZE}
    
    dd if=/dev/zero of="${img}" bs=512 count=1 seek=$(($img_size/512 - 1)) >/dev/null 2>/dev/null
    [ -s "${img}" ] || error "mk_disk_image: couldn't create file ${img}"
    local cylinders=$((${img_size} / (512 * ${DEFAULT_IMG_HEADS} * ${DEFAULT_IMG_SECTORS})))
    # Use a smaller block count to avoid filesystem/physical size issues
    local blocks=$((((${cylinders} - 1) * ${DEFAULT_IMG_HEADS} * ${DEFAULT_IMG_SECTORS} * ${DEFAULT_IMG_SECTOR_SIZE}) / ${DEFAULT_FS_BLOCK_SIZE}))
    ${SUDO} losetup -f "${img}" || \
        error "mk_disk_image: losetup returned error code $? for ${img}"
    regex_img=$(echo "${img}" | sed -e's/\./\\./g' -e's/\//\\\//g')
    img_dev=$(${SUDO} losetup -a | awk "/${regex_img}\\)\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${img_dev}" ] || \
        error "mk_disk_image: didn't grok the loop dev for whole image of ${img}"
    isloop "${img_dev}" || \
        error "mk_disk_image: ${img_dev} is not a ready loop device"
    [ -b "${img_dev}" ] || error "mk_disk_image: ${img_dev} is not a block device"
    ${SUDO} sfdisk -qD -C${cylinders} -H${DEFAULT_IMG_HEADS} \
        -S${DEFAULT_IMG_SECTORS} "${img_dev}"<<EOF || \
        error "sfdisk returned error code $?"
,,L,*
;
;
;
EOF
    local offset=$((${DEFAULT_IMG_SECTORS} * ${DEFAULT_IMG_SECTOR_SIZE}))
    ${SUDO} losetup -f -o ${offset} "${img}" || \
        error "mk_disk_image: losetup returned error code $? for ${img} offset ${offset}"
    part_dev=$(${SUDO} losetup -a | awk "/${regex_img}\\), offset ${offset}\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${part_dev}" ] || \
        error "mk_disk_image: didn't grok the loop dev for partition on image ${img}"
    isloop "${part_dev}" || \
        error "mk_disk_image: ${part_dev} is not a ready loop device"
    [ -b "${part_dev}" ] || \
    error "mk_disk_image: ${part_dev} is not a block device"
    echo y | ${SUDO} mkfs.ext3 -L root -b ${DEFAULT_FS_BLOCK_SIZE} ${part_dev} \
        ${blocks} ||  error "mk_disk_image: mkfs.ext3 returned error code $?"
}

# Make a filesystem image with filename $1 of size $2 and setup block device to
# access the filesystem. Note this is not a full disk image
# Sets the global var $part_dev
mk_fs_image()
{
    local img=
    local img_size=
    [ $# -ge 1 ] && img="$1"
    [ $# -ge 2 ] && img_size="$2"
    [ -z "${img}" ] && error "mk_fs_image: filename for image must be specified"
    local img_dir=$(dirname "${img}")
    dont_be_stupid "${img_dir}"
    [ -d "${img_dir}" ] || mkdir -p "${img_dir}"
    [ -d "${img_dir}" ] || error "mk_fs_image: ${img_dir} does not exist"
    [ -r "${img}" ] && ${SUDO} rm -f "${img}"
    [ -r "${img}" ] && error "mk_fs_image: ${img} already exists"
    flavour_stage mk_fs_image "${img}" "${img_size}"
    distro_stage mk_fs_image "${img}" "${img_size}"
    custom_stage mk_fs_image "${img}" "${img_size}"
    [ ${img_size} -ne ${img_size} >/dev/null 2>/dev/null ]
    if [ $? -ne 1 -a -n "${img_size}" ]; then
        warn "mk_fs_image: image size is not a number: ${img_size}"
        img_size=
    fi
    [ -z "${img_size}" ] && \
        warn "mk_fs_image: image size is unspecified, using default value [${DEFAULT_IMG_SIZE}]"
    [ -z "${img_size}" ] && img_size=${DEFAULT_IMG_SIZE}
    
    dd if=/dev/zero of="${img}" bs=512 count=1 seek=$(($img_size/512 - 1)) >/dev/null 2>/dev/null
    [ -s "${img}" ] || error "mk_fs_image: couldn't create file ${img}"
    ${SUDO} losetup -f "${img}" || \
        error "mk_fs_image: losetup returned error code $? for ${img}"
    regex_img=$(echo "${img}" | sed -e's/\./\\./g' -e's/\//\\\//g')
    part_dev=$(${SUDO} losetup -a | awk "/${regex_img}\\)\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${part_dev}" ] || \
        error "mk_fs_image: didn't grok the loop dev for image ${img}"
    isloop "${part_dev}" || \
        error "mk_fs_image: ${part_dev} is not a ready loop device"
    [ -b "${part_dev}" ] || \
    error "mk_fs_image: ${part_dev} is not a block device"
    echo y | ${SUDO} mkfs.ext3 -L root ${part_dev} || \
        error "mk_fs_image: mkfs.ext3 returned error code $?"
}

# Install grub to the image on $img_dev mounted at $1
mk_bootable()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "mk_bootable: base directory is unspecified"
    dont_be_stupid "${base}"
    [ -d "${base}" ] || error "mk_bootable: ${base} directory is invalid"
    ismounted "${base}" || error "mk_bootable: ${base} is not mounted"
    [ -z "${img_dev}" ] && \
        error "mk_bootable: loop device \$img_dev is unspecified"
    isloop "${img_dev}" || \
        error "mk_bootable: ${img_dev} is not an active loop device"
    [ -b "${img_dev}" ] || error "mk_image: ${img_dev} is not a block device"
    ${SUDO} mkdir -p "${base}/boot/grub" || \
        error "mk_bootable: could not create grub directory"
    ${SUDO} sh -c "echo \"(hd0) ${img_dev}\" > \"${base}/boot/grub/device.map\"" || \
        error "mk_bootable: could not install grub device map to ${base}/boot/grub/device.map"
    ${SUDO} grub-install --root-directory="${base}" --modules=part_msdos \
        ${img_dev} || \
        error "mk_bootable: grub-install failed: returned error code $?"
    mk_grub_cfg "${base}"
}

# Generate a grub configuration for installation at $1. If $2 is not null
# create a pvgrub menu
mk_grub_cfg()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "mk_grub_cfg: base directory is unspecified"
    dont_be_stupid "${base}"
    [ -d "${base}" ] || error "mk_grub_cfg: ${base} directory is invalid"
    [ -d "${base}/boot/grub" ] || ${SUDO} mkdir -p "${base}/boot/grub"
    local pvgrub=
    [ $# -ge 2 ] && pvgrub="$2"
    local cfg=
    if [ -n "$pvgrub" ]; then
	cfg="${base}/boot/grub/menu.lst"
	mk_pvgrub_header "${cfg}"
    else
	cfg="${base}/boot/grub/grub.cfg"
	[ -e "${base}/boot/grub/menu.lst" ] \
	    && ${SUDO} rm -f "${base}/boot/grub/menu.lst"
	mk_grub_header "${cfg}"
    fi
    local vmlinuz=
    local version=
    local initrd=
    for v in "${base}/boot/vmlinuz*"; do
        vmlinuz=$(basename ${v})
        version=$(echo "${vmlinuz}" | sed -e's/vmlinuz-//g')
        initrd=$(find "${base}/boot/" -iname "init*${version}*" | grep -v '.bak$')
        if [ -n "${vmlinuz}" ]; then
	    [ -n "${pvgrub}" ] && \
		mk_pvgrub_entry "${cfg}" "${vmlinuz}" "${initrd}"
	    [ -z "${pvgrub}" ] && \
		mk_grub_entry "${cfg}" "${vmlinuz}" "${initrd}"
        fi
    done
    flavour_stage mk_grub_cfg "${base}"
    distro_stage mk_grub_cfg "${base}"
    custom_stage mk_grub_cfg "${base}"
}

# Create a pvgrub style header
mk_pvgrub_header()
{
    local cfg=
    [ $# -ge 1 ] && cfg="$1"
    [ -z "${cfg}" ] && error "mk_pvgrub_header: \$cfg is unspecified"
    ${SUDO} sh -c "cat > \"${cfg}\"" <<EOF
default 0
timeout 1
EOF
}

# Add a pvgrub style entry
mk_pvgrub_entry()
{
    local cfg=
    [ $# -ge 1 ] && cfg="$1"
    [ -z "${cfg}" ] && error "mk_pvgrub_entry: \$cfg is unspecified"
    local vmlinuz=
    [ $# -ge 2 ] && vmlinuz="$2"
    [ -z "${vmlinuz}" ] && error "mk_pvgrub_entry: \$vmlinuz is unspecified"
    local initrd=
    [ $# -ge 3 ] && initrd="$3"
    ${SUDO} sh -c "cat >> \"${cfg}\"" <<EOF

title Linux ${version}
    root (hd0)
    kernel /boot/$(basename "${vmlinuz}") root=LABEL=root
EOF
    if [ -n "${initrd}" ]; then
        ${SUDO} sh -c "cat >> \"${cfg}\"" <<EOF
    initrd /boot/$(basename "${initrd}")
EOF
    fi
}

# Create a new grub style header
mk_grub_header()
{
    local cfg=
    [ $# -ge 1 ] && cfg="$1"
    [ -z "${cfg}" ] && error "mk_grub2_header: \$cfg is unspecified"
    ${SUDO} sh -c "cat > \"${cfg}\"" <<EOF
set default=0
set timeout=10
EOF
}

# Add a new grub style entry
mk_grub_entry()
{
    local cfg=
    [ $# -ge 1 ] && cfg="$1"
    [ -z "${cfg}" ] && error "mk_grub_entry: \$cfg is unspecified"
    local vmlinuz=
    [ $# -ge 2 ] && vmlinuz="$2"
    [ -z "${vmlinuz}" ] && error "mk_grub_entry: \$vmlinuz is unspecified"
    local initrd=
    [ $# -ge 3 ] && initrd="$3"
    ${SUDO} sh -c "cat >> \"${cfg}\"" <<EOF

menuentry 'Linux ${version}' {
    set root=(hd0,msdos1)
    linux /boot/$(basename "${vmlinuz}") root=LABEL=root
EOF
    if [ -n "${initrd}" ]; then
        ${SUDO} sh -c "cat >> \"${cfg}\"" <<EOF
    initrd /boot/$(basename "${initrd}")
EOF
    fi
    ${SUDO} sh -c "cat >> \"${cfg}\"" <<EOF
}
EOF
}

# Launch the specified image file $1 in KVM
launch_img()
{
    local img=
    [ $# -ge 1 ] && img="$1"
    [ -z "${img}" ] && error "launch_img: \$img is unspecified"
    dont_be_stupid "${img}"
    [ -r "${img}" ] || error "launch_img: file ${img} is invalid"
    local mac=
    local qemu_cpu=
    [ "x86_64" = "${AMI_ARCH}" ] && qemu_cpu="qemu64"
    [ -z "${qemu_cpu}" ] && qemu_cpu="qemu32"
    
    # Get a mac address to use; keep it constant to avoid udev problems when
    # relaunching an instance
    mac="54:52:00:00:00:99"
    flavour_stage launch_img "${img}"
    distro_stage launch_img "${img}"
    custom_stage launch_img "${img}"

    # Launch image in KVM with audio and usb support, emulating IDE
    env QEMU_AUDIO_DRV=${QEMU_AUDIO_DRV:-"alsa"} \
        kvm -name "${img}" -cpu ${qemu_cpu} -soundhw ac97 \
        -rtc base=utc,clock=host \
        -net nic,vlan=0,model=${KVM_NET:-${DEFAULT_KVM_NET}},macaddr=${mac} \
        -net vde,vlan=0,sock=/var/run/vde2/tap0.ctl,mode=0660 \
        -m ${KVM_MEM:-${DEFAULT_KVM_MEM}} -usb -usbdevice tablet \
        -drive file="${img}",if=ide,index=0,cache=none,media=disk
}

# Helper to make sure that EC2 environment is setup
ec2_validate()
{
    local missing=
    local exec=
    [ -z "${EC2_USER_ID}" ] && missing="${missing}${missing:+, }\$EC2_USER_ID"
    [ -z "${EC2_PRIVATE_KEY}" ] && \
        missing="${missing}${missing:+, }\$EC2_PRIVATE_KEY"
    [ -z "${EC2_CERT}" ] && missing="${missing}${missing:+, }\$EC2_CERT"
    [ -z "${EC2_ACCESS_KEY}" ] && \
        missing="${missing}${missing:+, }\$EC2_ACCESS_KEY"
    [ -z "${EC2_SECRET_KEY}" ] && \
        missing="${missing}${missing:+, }\$EC2_SECRET_KEY"
    [ -n "${missing}" ] && \
        warn "ec2_validate: the following environment variables are unset: ${missing}"
    which ec2-bundle-image >/dev/null 2>/dev/null || \
        exec="${exec}${exec:+, }ec2-bundle-image"
    which ec2-upload-bundle >/dev/null 2>/dev/null || \
        exec="${exec}${exec:+, }ec2-upload-bundle"
    which ec2-register >/dev/null 2>/dev/null || \
        exec="${exec}${exec:+, }ec2-register"
    [ -n "${exec}" ] && \
        warn "ec2_validate: the following executables are missing: ${exec}"
    [ -n "${missing}" -o -n "${exec}" ] && \
        error "ec2_validate: cannot perform AMI actions, exiting"
    flavour_stage "ec2_validate"
    distro_stage "ec2_validate"
    custom_stage "ec2_validate"
}

# Process supplied image $1 to an AMI bundle
bundle_ami()
{
    local img=
    local img_tmp=${AMI_TMP:-${DEFAULT_AMI_TMP}}
    [ $# -ge 1 ] && img="$1"
    [ -s "${img}" ] || error "bundle_ami: image file ${img} is invalid"
    dont_be_stupid "${img_tmp}"
    local block_mappings="--block-device-mapping ami=sda1,root=/dev/sda1"
    local kernel_id=$(get_kernel_id)
    local ramdisk_id=$(get_ramdisk_id)
    [ "i386" = "${AMI_ARCH}" ] && \
        block_mappings="${block_mappings},ephemeral0=sda2,swap=sda3"
    [ "x86_64" = "${AMI_ARCH}" ] && \
        block_mappings="${block_mappings},ephemeral0=sdb,ephemeral1=sdc"
    flavour_stage bundle_ami "${img}"
    distro_stage bundle_ami "${img}"
    custom_stage bundle_ami "${img}"
    ec2-bundle-image -k ${EC2_PRIVATE_KEY} \
        -c ${EC2_CERT} \
        -u $(echo "${EC2_USER_ID}" | tr -d '-') \
        -i "${img}" \
        -r ${AMI_ARCH} \
        ${img_tmp:+-d "${img_tmp}"} \
        ${AMI_PREFIX:+-p "${AMI_PREFIX}"} \
        ${kernel_id:+--kernel "${kernel_id}"} \
        ${ramdisk_id:+--ramdisk "${ramdisk_id}"} \
        ${block_mappings}
}

# Upload and register AMIs to bucket $2, registered as name $3
upload_ami()
{
    local ami=
    local bucket=
    local name=
    local ami_tmp=${AMI_TMP:-${DEFAULT_AMI_TMP}}
    [ $# -ge 1 ] && ami="$1"
    [ $# -ge 2 ] && bucket="$2"
    [ $# -ge 3 ] && name="$3"
    [ $# -ge 4 ] && description="$4"
    flavour_stage upload_ami "${ami}" "${bucket}" "${name}" "${description}"
    distro_stage upload_ami "${ami}" "${bucket}" "${name}" "${description}"
    custom_stage upload_ami "${ami}" "${bucket}" "${name}" "${description}"
    [ -z "${ami}" ] && error "upload_ami: \$ami is unspecified"
    [ -s "${ami_tmp}/${ami}.manifest.xml" ] || \
        error "upload_ami: ${ami_tmp}/${ami}.manifest.xml is empty or missing"
    [ -z "${bucket}" ] && error "upload_ami: \$bucket is unspecified"
    [ -z "${name}" ] && error "upload_ami: \$name is unspecified"
    [ -n "${name}" -a ${#name} -ge 3 -a ${#name} -le 128 ] || \
        error "upload_ami: name ${name} does not meet size requirements"
    [ -n "${description}" -a ${#description} -ge 1 -a ${#description} -le 255 ] || \
        error "upload_ami: description '${description}' does not meet size requirements"
    local acl=
    [ "public-read" = "${AMI_ACL}" -o "aws-exec-read" = "${AMI_ACL}" ] && \
        acl=${AMI_ACL}
    local kernel_id=$(get_kernel_id)
    local ramdisk_id=$(get_ramdisk_id)
    ec2-upload-bundle -b ${bucket} \
        -m "${ami_tmp}/${ami}.manifest.xml" \
        -a ${EC2_ACCESS_KEY} \
        -s ${EC2_SECRET_KEY} \
        ${AMI_ACL:+--acl "${AMI_ACL}"} \
        ${ami_tmp:+-d "${ami_tmp}"} \
        ${AMI_PART:+--part "${AMI_PART}"} \
        ${AMI_LOCATION:+--location "${AMI_LOCATION}"} \
        ${AMI_URL:+--url "${AMI_URL}"} \
        ${AMI_RETRY:+--retry "${AMI_RETRY}"} \
        ${AMI_SKIPMANIFEST:+--skipmanifest} || \
        error "upload_ami: ec2-upload-bundle returned error code $?"
    ec2-register ${bucket}/${ami}.manifest.xml \
        ${name:+-n "${name}"} \
        ${description:+-d "${description}"} \
	${AMI_LOCATION:+--region "${AMI_LOCATION}"} || \
        error "upload_ami: ec2-register returned error code $?"
}

# Return a filename for the AMI image
get_ami_img_name()
{
    local img_name="$(custom_stage get_ami_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    img_name="$(distro_stage get_ami_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    img_name="$(flavour_stage get_ami_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    echo "${AMI_ARCH}.ami.img"
}

# Return a file size for the AMI image
get_ami_img_size()
{
    local img_size=$(custom_stage get_ami_img_size)
    [ ${img_size} -gt 0 2>/dev/null ] && echo ${img_size} && return
    img_size=$(distro_stage get_ami_img_size)
    [ ${img_size} -gt 0 2>/dev/null ] && echo ${img_size} && return
    img_size=$(flavour_stage get_ami_img_size)
    [ ${img_size} -gt 0 2>/dev/null ] && echo ${img_size} && return
    echo ${DEFAULT_IMG_SIZE}
}

# Return a name for the AMI image
get_ami_name()
{
    local name="$(custom_stage get_ami_name)"
    [ -n "${name}" ] && echo "${name}" && return
    name="$(distro_stage get_ami_name)"
    [ -n "${name}" ] && echo "${name}" && return
    name="$(flavour_stage get_ami_name)"
    [ -n "${name}" ] && echo "${name}" && return
    echo "Unspecified ${AMI_ARCH}"
}

# Return a description for the AMI image
get_ami_description()
{
    local description="$(custom_stage get_ami_description)"
    [ -n "${description}" ] && echo "${description}" && return
    description="$(distro_stage get_ami_description)"
    [ -n "${description}" ] && echo "${description}" && return
    description="$(flavour_stage get_ami_description)"
    [ -n "${description}" ] && echo "${description}" && return
    echo "Unspecified ${AMI_ARCH} image of $(date '+%H:%M %Z %m/%d/%y')"
}

# Return a bucket for upload of AMI image
get_ami_bucket()
{
    local bucket="$(custom_stage get_ami_bucket)"
    [ -n "${bucket}" ] && echo "${bucket}" && return
    bucket="$(distro_stage get_ami_bucket)"
    [ -n "${bucket}" ] && echo "${bucket}" && return
    bucket="$(flavour_stage get_ami_bucket)"
    [ -n "${bucket}" ] && echo "${bucket}" && return
    echo "${DEFAULT_AMI_BUCKET}"
}

# Return a filename for a KVM image
get_kvm_img_name()
{
    local img_name="$(custom_stage get_kvm_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    img_name="$(distro_stage get_kvm_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    img_name="$(flavour_stage get_kvm_img_name)"
    [ -n "${img_name}" ] && echo "${img_name}" && return
    echo "${AMI_ARCH}.kvm.img"
}

# Return a file size for a KVM image
get_kvm_img_size()
{
    local img_size=$(custom_stage get_kvm_img_size)
    [ ${img_size} -ne 0 2>/dev/null ] && echo ${img_size} && return
    img_size=$(distro_stage get_kvm_img_size)
    [ ${img_size} -ne 0 2>/dev/null ] && echo ${img_size} && return
    img_size=$(flavour_stage get_kvm_img_size)
    [ ${img_size} -ne 0 2>/dev/null ] && echo ${img_size} && return
    echo ${DEFAULT_IMG_SIZE}
}

# Prepare the mounted ami image before copying files; just a place-holder
# for distro and custom hooks
pre_ami_image()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "pre_ami_image: \$base is unspecified"
    flavour_stage pre_ami_image "${base}"
    distro_stage pre_ami_image "${base}"
    custom_stage pre_ami_image "${base}"
}

# Finalise the mounted ami image before further actions; just a place-holder
# for distro and custom hooks
post_ami_image()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "post_post_ami_image: \$base is unspecified"
    flavour_stage post_ami_image "${base}"
    distro_stage post_ami_image "${base}"
    custom_stage post_ami_image "${base}"
}

# Prepare the mounted kvm image before copying files; just a place-holder
# for distro and custom hooks
pre_kvm_image()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "pre_kvm_image: \$base is unspecified"
    dont_be_stupid "${base}"
    flavour_stage pre_kvm_image "${base}"
    distro_stage pre_kvm_image "${base}"
    custom_stage pre_kvm_image "${base}"
}

# Finalise the mounted kvm image before further actions; just a place-holder
# for distro and custom hooks
post_kvm_image()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "post_kvm_image: \$base is unspecified"
    dont_be_stupid "${base}"
    flavour_stage post_kvm_image "${base}"
    distro_stage post_kvm_image "${base}"
    custom_stage post_kvm_image "${base}"
}

# Function to return the base directory to use
get_base_directory()
{
    local base=$(custom_stage get_base_directory)
    [ -z "${base}" ] && base=$(distro_stage get_base_directory)
    [ -z "${base}" ] && base=$(flavour_stage get_base_directory)
    echo "${base}"
}

# Function to return the mount point directory to use for loopback images
get_img_mount_point()
{
    local mount_point=$(custom_stage get_img_mount_point)
    [ -z "${mount_point}" ] && mount_point=$(distro_stage get_img_mount_point)
    [ -z "${mount_point}" ] && \
	mount_point=$(flavour_stage get_img_mount_point)
    echo "${mount_point}"
}

# Handle initialisation functions prior to chrooting and image creation
# Provides a hook for building options on EBS, etc
initialise()
{
    flavour_stage initialise $@
    distro_stage initialise $@
    custom_stage initialise $@
}

# Handle finalisation functions prior to exiting the scripts
# Provides a hook for building options on EBS, etc
finalise()
{
    flavour_stage finalise $@
    distro_stage finalise $@
    custom_stage finalise $@
}

# Handle KVM image creation and launch, as determined by flavour script only
do_kvm()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "do_kvm: \$base is unspecified"
    # Only allow flavour to perform this step
    flavour_stage do_kvm "${base}"
}

# Handle AMI image creation and registration, as determined by flavour script
# only
do_ami()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "do_ami: \$base is unspecified"
    # Only allow flavour to perform this step
    flavour_stage do_ami "${base}"
}

# Get the best kernel id for an instance
get_kernel_id()
{
    local kernel_id=$(eval "echo \${EC2_DEFAULT_KERNEL_ID_${AMI_ARCH}}")
    [ -z "${kernel_id}" ] && kernel_id=$(custom_stage get_kernel_id $@)
    [ -z "${kernel_id}" ] && kernel_id=$(distro_stage get_kernel_id $@)
    [ -z "${kernel_id}" ] && kernel_id=$(flavour_stage get_kernel_id $@)
    if [ -z "${kernel_id}" ]; then
	support_pvgrub
	if [ $? -eq 0 ]; then
	    # No kernel_id specified, so try to find best matching pvgrub
	    kernel_id=$(ec2-describe-images --owner self --owner amazon \
		--filter "architecture=${AMI_ARCH}" \
		--filter "image-type=kernel" \
		--filter "manifest-location=*pv-grub-hd0_1*" \
		${AMI_LOCATION:+--region "${AMI_LOCATION}"} | cut -f2)
	    [ -z "${kernel_id}" ] && \
		error "get_kernel_id: system is expecting a pvgrub kernel, but none found"
	fi
    fi
    echo "${kernel_id}"
}

# Get the best ramdisk id for an instance
get_ramdisk_id()
{
    local ramdisk_id=$(eval "echo \${EC2_DEFAULT_RAMDISK_ID_${AMI_ARCH}}")
    [ -z "${ramdisk_id}" ] && ramdisk_id=$(custom_stage get_ramdisk_id $@)
    [ -z "${ramdisk_id}" ] && ramdisk_id=$(distro_stage get_ramdisk_id $@)
    [ -z "${ramdisk_id}" ] && ramdisk_id=$(flavour_stage get_ramdisk_id $@)
    echo "${ramdisk_id}"
}

# Return 0 if all the functions support pvgrub
support_pvgrub()
{
    if [ -n "$(flavour_stage support_pvgrub)" -a \
	-n "$(distro_stage support_pvgrub)" ]; then
	return 0
    fi
    return 1
}

# Return a kernel package
get_kernel_pkg()
{
    local kernel_pkg=$(custom_stage get_kernel_pkg)
    [ -z "${kernel_pkg}" ] && kernel_pkg=$(distro_stage get_kernel_pkg)
    [ -z "${kernel_pkg}" ] && kernel_pkg=$(flavour_stage get_kernel_pkg)
    echo "${kernel_pkg}"
}