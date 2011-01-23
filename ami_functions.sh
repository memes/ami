#! /bin/sh
#
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

# Store modified fs mounts for dev/nodev
nodev_mounts=""

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
    sudo losetup -a 2>/dev/null | grep -q "$1" >/dev/null 2>/dev/null
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
    file=$(readlink -f "${file}")
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
    grep -q "${mnt}.*nodev" /proc/mounts >/dev/null 2>/dev/null
    if [ $? -eq 0 ]; then
	# Add this mount point to list of modified mount points, if not already
	# accounted for
	echo "${nodev_mounts}" | grep -q ":${mnt}:" >/dev/null 2>/dev/null || \
	    nodev_mounts="${nodev_mounts}:${mnt}:"
        sudo mount -o remount,dev "${mnt}"
    fi
    grep -q "${mnt}.*nodev" /proc/mounts >/dev/null 2>/dev/null && \
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
    local mnt=$(get_mountpoint "${base}")
    [ -z "${mnt}" ] && \
        warn "disable_dev_files_for: no mount point found for ${base}" && \
        return
    grep -q "${mnt}.*nodev" /proc/mounts >/dev/null 2>/dev/null
    if [ $? -ne 0 ]; then
	# Check the nodev_mounts to see if the script made this mount point
	# support devices where previously it was disabled and remount only then
	echo "${nodev_mounts}" | grep -q ":${mnt}:" >/dev/null 2>/dev/null
	if [ $? -eq 0 ]; then
	    # This mount was remounted with dev support by this script, allow
            # remount
	    local sanitised_mnt=$(echo "${mnt}" | sed -e's/\//\\\//g')
	    nodev_mounts=$(echo "${nodev_mounts}" | sed -e"s/:${sanitised_mnt}://g")
	    sudo mount -o remount,nodev "${mnt}"
	    grep -q "${mnt}.*nodev" /proc/mounts >/dev/null 2>/dev/null || \
		warn "disable_dev_files_for: ${mnt} is still mounted with dev support"
	fi
    fi
}

# Clean up any resources remaining from build
cleanup ()
{
    disable_dev_files_for "${BASEDIR}"
    [ -n "${BASEDIR}" ] && ismounted "${BASEDIR}/proc" && \
	    sudo umount "${BASEDIR}/proc"
    [ -n "${BASEDIR}" ] && ismounted "${BASEDIR}/sys" && \
	    sudo umount "${BASEDIR}/sys"
    [ -n "${MOUNTDIR}" ] && ismounted "${MOUNTDIR}/proc" && \
	    sudo umount "${MOUNTDIR}/proc"
    [ -n "${MOUNTDIR}" ] && ismounted "${MOUNTDIR}/sys" && \
	    sudo umount "${MOUNTDIR}/sys"
    [ -n "${MOUNTDIR}" ] && ismounted "${MOUNTDIR}" && sudo umount "${MOUNTDIR}"
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
	    sudo losetup -d "${part_dev}"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
	    sudo losetup -d "${img_dev}"
}

# Validate the environment is ready for use
prebuild_validate()
{
    [ -z "${AMI_ARCH}" ] && \
	    error "prebuild_validate: AMI architecture must be specified in \$AMI_ARCH"
    [ "i386" = "${AMI_ARCH}" -o "x86_64" = "${AMI_ARCH}" ] || \
	    error "prebuild_validate: AMI architecture must be i386 or x86_64: ${AMI_ARCH} is invalid"
    [ "x86_64" = "${AMI_ARCH}" -a "x86_64" != "$(arch)" ] && \
	    error "prebuild_validate: cannot build ${AMI_ARCH} install on $(arch) host"
}

# Prepare to chroot to $1
prepare_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "prepare_chroot: \$base is unspecified"
    [ -d "${base}" ] || error "prepare_chroot: directory ${base} is invalid"
    enable_dev_files_for "${base}"
    sudo mkdir -p "${base}/proc" "${base}/sys"
    [ -d "${base}/proc" ] || error "prepare_chroot: ${base}/proc does not exist"
    [ -d "${base}/sys" ] || error "prepare_chroot: ${base}/sys does not exist"
    ismounted "${base}/proc" || sudo mount --bind /proc "${base}/proc"
    ismounted "${base}/proc" || \
        error "prepare_chroot: ${base}/proc is not mounted"
    ismounted "${base}/sys" || sudo mount --bind /sys "${base}/sys"
    ismounted "${base}/sys" || \
	    error "prepare_chroot: ${base}/sys is not mounted"
}

# Remove chroot specific mounts in $1
post_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "post_chroot: \$base is unspecified"
    disable_dev_files_for "${base}"
    ismounted "${base}/proc" && sudo umount "${base}/proc"
    ismounted "${base}/sys" && sudo umount "${base}/sys"
    ismounted "${base}/proc" && \
        error "post_chroot: ${base}/proc is still mounted"
    ismounted "${base}/sys" && error "post_chroot: ${base}/sys is still mounted"
}

# Clean up an existing chroot at $1
rm_chroot()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "rm_chroot: \$base is unspecified"
    post_chroot "${base}"
    [ -d "${base}" ] && sudo rm -rf "${base}"
    [ -d "${base}" ] && error "rm_chroot: ${base} still exists"
}

# mount an image on $part_dev at $1
mount_img()
{
    local mnt=
    [ $# -ge 1 ] && mnt="$1"
    [ -z "${mnt}" ] && error "mount_img: \$mnt is unspecified"
    [ -d "${mnt}" ] || mkdir -p "${mnt}"
    [ -d "${mnt}" ] || error "mount_img: directory ${mnt} does not exist"
    [ -d "${mnt}/proc" ] && ismounted "${mnt}/proc" && sudo umount "${mnt}/proc"
    ismounted "${mnt}/proc" && error "mount_img: ${mnt}/proc is still mounted"
    [ -d "${mnt}/sys" ] && ismounted "${mnt}/sys" && sudo umount "${mnt}/sys"
    ismounted "${mnt}/sys" && error "mount_img: ${mnt}/sys is still mounted"
    ismounted "${mnt}" && sudo umount "${mnt}"
    ismounted "${mnt}" && \
        error "mount_img: ${mnt} is still mounted from previous activity"
    [ -z "${part_dev}" ] && error "mount_img: mount device is unspecified"
    [ -b "${part_dev}" ] || error "mount_img: ${part_dev} is not a block device"
    sudo mount ${part_dev} "${mnt}" || \
        error "mount_img: unable to mount ${part_dev} at ${mnt}: returned error code $?"
}

# unmount the image $1 and release loop devices
umount_img()
{
    local mnt=
    [ $# -ge 1 ] && mnt="$1"
    [ -z "${mnt}" ] && error "umount_img: \$mnt is unspecified"
    ismounted "${mnt}" && sudo umount "${mnt}"
    ismounted "${mnt}" && error "umount_img: ${mnt} is still mounted"
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
        sudo losetup -d "${part_dev}"
    [ -n "${part_dev}" ] && isloop "${part_dev}" && \
        error "umount_img: ${part_dev} is still a loop device"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
        sudo losetup -d "${img_dev}"
    [ -n "${img_dev}" ] && isloop "${img_dev}" && \
        error "umount_img: ${img_dev} is still a loop device"
}

# Create an fstab file for the instance at $1
update_fstab()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "update_fstab: \$base is unspecified"
    [ -d "${base}/etc" ] || \
	    error "update_fstab: ${base}/etc does not exist"
    sudo sh -c "cat > \"${base}/etc/fstab\"" <<EOF
/dev/sda1       /               ext3        defaults        0        1
none            /dev/pts        devpts      defaults        0        0
none            /dev/shm        tmpfs       gid=5,mode=620  0        0
none            /proc           proc        defaults        0        0
none            /sys            sysfs       defaults        0        0
EOF

    if [ "i386" = "${AMI_ARCH}" ]; then
	    sudo sh -c "cat >> \"${base}/etc/fstab\"" <<EOF
# 32 bit (m1.small and c1.medium instances)
/dev/sda2       /mnt            ext3        defaults,noauto 0        0
/dev/sda3       swap            swap        defaults        0        0
EOF
    fi

    if [ "x86_64" = "${AMI_ARCH}" ]; then
	    sudo sh -c "cat >> \"${base}/etc/fstab\"" <<EOF
# 64 bit (m1.large, m1.xlarge, c1.xlarge, cc1.4xlarge, cg1.4xlarge,
# m2.xlarge, m2.2xlarge, and m2.4xlarge instances)
/dev/sdb        /mnt            ext3        defaults,noauto 0        0
/dev/sdc        /mnt            ext3        defaults,noauto 0        0
EOF
    fi
    [ -s "${base}/etc/fstab" ] || \
        error "update_fstab: ${base}/etc/fstab is missing or empty"
}

# Update sshd configuration at $1
update_sshd()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "update_sshd: \$base is unspecified"
    [ -e "${base}/etc/ssh/sshd_config" ] || \
	    error "update_sshd: ${base}/etc/ssh/sshd_config does not exist"
    sudo cp "${base}/etc/ssh/sshd_config" /tmp/sshd_config
    sudo sh -c "sed -e'/^#\?PermitRootLogin/cPermitRootLogin without-password' -e'/^#\?UseDNS/cUseDNS no' /tmp/sshd_config > \"${base}/etc/ssh/sshd_config\""
    sudo rm -f /tmp/sshd_config
    sudo grep -q "^PermitRootLogin without-password" "${base}/etc/ssh/sshd_config" >/dev/null 2>/dev/null || \
	    error "update_sshd: ${base}/etc/ssh/sshd_config is not updated"
}

# Add memes public ssh keys to memes account at $1
# Folder for the keys should have already been created and given correct
# ownership/permissions
add_memes_keys()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "add_memes_keys: \$base is unspecified"
    sudo sh -c "[ -d \"${base}/home/memes/.ssh\" ] || mkdir -p \"${base}/home/memes/.ssh\""
    if [ -d /media/protected/.ssh ]; then
	    for key in /media/protected/.ssh/memes@aaxisgroup.com*pub
        do sudo sh -c "cat ${key} >> \"${base}/home/memes/.ssh/authorized_keys2\""
	    done
    else
	    [ -d ~/.ssh/ ] && \
	        for key in ~/.ssh/*pub
        do sudo sh -c "cat ${key} >> \"${base}/home/memes/.ssh/authorized_keys2\""
	    done
    fi
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
    [ -z "${img}" ] && error "mk_disk_image: filename for image must be specified"
    local img_dir=$(dirname "${img}")
    [ -d "${img_dir}" ] || mkdir -p "${img_dir}"
    [ -d "${img_dir}" ] || error "mk_disk_image: ${img_dir} does not exist"
    [ -r "${img}" ] && sudo rm -f "${img}"
    [ -r "${img}" ] && error "mk_disk_image: ${img} already exists"
    [ ${img_size} -ne ${img_size} >/dev/null 2>/dev/null ]
    if [ $? -ne 1 -a -n "${img_size}" ]; then
        warn "mk_disk_image: image size is not a number: ${img_size}"
        img_size=
    fi
    [ -z "${img_size}" ] && \
        warn "mk_disk_image: image size is unspecified, using default value [${DEFAULT_IMG_SIZE}]"
    [ -z "${img_size}" ] && img_size=${DEFAULT_IMG_SIZE}
    
    dd if=/dev/zero of="${img}" bs=512 count=1 seek=$(($img_size/512 - 1))
    [ -s "${img}" ] || error "mk_disk_image: couldn't create file ${img}"
    local cylinders=$((${img_size} / (512 * ${DEFAULT_IMG_HEADS} * ${DEFAULT_IMG_SECTORS})))
    # Use a smaller block count to avoid filesystem/physical size issues
    local blocks=$((((${cylinders} - 1) * ${DEFAULT_IMG_HEADS} * ${DEFAULT_IMG_SECTORS} * ${DEFAULT_IMG_SECTOR_SIZE}) / ${DEFAULT_FS_BLOCK_SIZE}))
    sudo losetup -f "${img}" || \
        error "mk_disk_image: losetup returned error code $? for ${img}"
    regex_img=$(echo "${img}" | sed -e's/\./\\./g' -e's/\//\\\//g')
    img_dev=$(sudo losetup -a | awk "/${regex_img}\\)\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${img_dev}" ] || \
        error "mk_disk_image: didn't grok the loop dev for whole image of ${img}"
    isloop "${img_dev}" || \
        error "mk_disk_image: ${img_dev} is not a ready loop device"
    [ -b "${img_dev}" ] || error "mk_disk_image: ${img_dev} is not a block device"
    sudo sfdisk -qD -C${cylinders} -H${DEFAULT_IMG_HEADS} \
        -S${DEFAULT_IMG_SECTORS} "${img_dev}"<<EOF || \
        error "sfdisk returned error code $?"
,,L,*
;
;
;
EOF
    local offset=$((${DEFAULT_IMG_SECTORS} * ${DEFAULT_IMG_SECTOR_SIZE}))
    sudo losetup -f -o ${offset} "${img}" || \
        error "mk_disk_image: losetup returned error code $? for ${img} offset ${offset}"
    part_dev=$(sudo losetup -a | awk "/${regex_img}\\), offset ${offset}\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${part_dev}" ] || \
        error "mk_disk_image: didn't grok the loop dev for partition on image ${img}"
    isloop "${part_dev}" || \
        error "mk_disk_image: ${part_dev} is not a ready loop device"
    [ -b "${part_dev}" ] || \
	error "mk_disk_image: ${part_dev} is not a block device"
    echo y | sudo mkfs.ext3 -L root -b ${DEFAULT_FS_BLOCK_SIZE} ${part_dev} \
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
    [ -d "${img_dir}" ] || mkdir -p "${img_dir}"
    [ -d "${img_dir}" ] || error "mk_fs_image: ${img_dir} does not exist"
    [ -r "${img}" ] && sudo rm -f "${img}"
    [ -r "${img}" ] && error "mk_fs_image: ${img} already exists"
    [ ${img_size} -ne ${img_size} >/dev/null 2>/dev/null ]
    if [ $? -ne 1 -a -n "${img_size}" ]; then
        warn "mk_fs_image: image size is not a number: ${img_size}"
        img_size=
    fi
    [ -z "${img_size}" ] && \
        warn "mk_fs_image: image size is unspecified, using default value [${DEFAULT_IMG_SIZE}]"
    [ -z "${img_size}" ] && img_size=${DEFAULT_IMG_SIZE}
    
    dd if=/dev/zero of="${img}" bs=512 count=1 seek=$(($img_size/512 - 1))
    [ -s "${img}" ] || error "mk_fs_image: couldn't create file ${img}"
    sudo losetup -f "${img}" || \
        error "mk_fs_image: losetup returned error code $? for ${img}"
    regex_img=$(echo "${img}" | sed -e's/\./\\./g' -e's/\//\\\//g')
    part_dev=$(sudo losetup -a | awk "/${regex_img}\\)\$/ {print \$1}" | cut -f1 -d:)
    [ -n "${part_dev}" ] || \
        error "mk_fs_image: didn't grok the loop dev for image ${img}"
    isloop "${part_dev}" || \
        error "mk_fs_image: ${part_dev} is not a ready loop device"
    [ -b "${part_dev}" ] || \
	error "mk_fs_image: ${part_dev} is not a block device"
    echo y | sudo mkfs.ext3 -L root ${part_dev} || \
	error "mk_fs_image: mkfs.ext3 returned error code $?"
}

# Modify filesystem for KVM
kvm_compatible_fs()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "kvm_compatible_fs: base directory is unspecified"
    [ -d "${base}" ] || error "kvm_compatible_fs: ${base} directory is invalid"
    [ -r "${base}/etc/fstab" ] || \
        error "kvm_compatible_fs: ${base}/etc/fstab is missing"
    sudo cp "${base}/etc/fstab" /tmp/fstab
    sudo sh -c "sed -e'/\/dev\/sda1/c/dev/hda1       /               ext3        defaults        0        1' /tmp/fstab > \"${base}/etc/fstab\""
    [ -s "${base}/etc/fstab" ] || \
        error "kvm_compatible_fs: ${base}/etc/fstab is missing or empty"
}

# Install grub to the image on $img_dev mounted at $1
mk_bootable()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "mk_bootable: base directory is unspecified"
    [ -d "${base}" ] || error "mk_bootable: ${base} directory is invalid"
    ismounted "${base}" || error "mk_bootable: ${base} is not mounted"
    [ -z "${img_dev}" ] && \
        error "mk_bootable: loop device \$img_dev is unspecified"
    isloop "${img_dev}" || \
        error "mk_bootable: ${img_dev} is not an active loop device"
    [ -b "${img_dev}" ] || error "mk_image: ${img_dev} is not a block device"
    sudo mkdir -p "${base}/boot/grub" || \
        error "mk_bootable: could not create grub directory"
    sudo sh -c "echo \"(hd0) ${img_dev}\" > \"${base}/boot/grub/device.map\"" ||
        error "mk_bootable: could not install grub device map to ${base}/boot/grub/device.map"
    sudo grub-install --root-directory="${base}" --modules=part_msdos \
        ${img_dev} || error "mk_bootable: grub-install failed: returned error code $?"
    mk_grub_cfg "${base}"
}

# Generate a grub configuration for installation at $1
mk_grub_cfg()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && error "mk_grub_cfg: base directory is unspecified"
    [ -d "${base}" ] || error "mk_grub_cfg: ${base} directory is invalid"
    sudo sh -c "cat > \"${base}/boot/grub/grub.cfg\"" <<EOF
set default=0
set timeout=10
EOF
    local vmlinuz=
    local version=
    local initrd=
    for v in "${base}/boot/vmlinuz*"; do
        vmlinuz=$(basename ${v})
        version=$(echo "${vmlinuz}" | sed -e's/vmlinuz-//g')
	initrd=$(find "${base}/boot/" -iname "initrd*${version}*")
        if [ -n "${vmlinuz}" ]; then
            sudo sh -c "cat >> \"${base}/boot/grub/grub.cfg\"" <<EOF

menuentry 'Linux${version}' {
    set root=(hd0,msdos1)
    linux /boot/${vmlinuz} root=/dev/hda1
EOF
	    if [ -n "${initrd}" ]; then
		sudo sh -c "cat >> \"${base}/boot/grub/grub.cfg\"" <<EOF
    initrd /boot/$(basename "${initrd}")
EOF
	    fi
            sudo sh -c "cat >> \"${base}/boot/grub/grub.cfg\"" <<EOF
}
EOF
        fi
    done
}

# Launch the specified image file $1 in KVM
launch_img()
{
    local img=
    [ $# -ge 1 ] && img="$1"
    [ -z "${img}" ] && error "launch_img: \$img is unspecified"
    [ -r "${img}" ] || error "launch_img: file ${img} is invalid"
    local mac=
    local qemu_cpu=
    [ "x86_64" = "${AMI_ARCH}" ] && qemu_cpu="qemu64"
    [ -z "${qemu_cpu}" ] && qemu_cpu="qemu32"

    # Get a mac address to use
    for i in $(seq 100); do
        mac="54:52:00:00:00:$(dd if=/dev/urandom bs=1 count=1 | od -t x1 | cut -d' ' -f2 | head -n 1)"
        [ ${#mac} -ne 17 ] && continue;
        # Not reliable over vde2, so skip and hope there are no collisions
        #    arping -qc 3 ${mac} >/dev/null 2>/dev/null || break
        break;
    done
    [ "$i" = "100" ] && error "launch_img: couldn't get an unused mac address"
    [ ${#mac} -ne 17 ] && \
        error "launch_img: couldn't generate a valid mac address"
    # Launch image in KVM with audio and usb support, emulating IDE
    env QEMU_AUDIO_DRV=${QEMU_AUDIO_DRV:-"alsa"} \
        kvm -name "CentOS ${CENTOS_VER} ${AMI_ARCH}" -cpu ${qemu_cpu} \
        -net nic,vlan=0,model=virtio,macaddr=${mac} \
        -net vde,vlan=0,sock=/var/run/vde2/tap0.ctl,mode=0660 \
        -m 512 -usb -usbdevice tablet \
        -drive file="${img}",if=ide,index=0,boot=on,media=disk
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
}

# Process supplied image $1 to an AMI bundle
bundle_ami()
{
    local img=
    local tmp=${AMI_TMP:-${DEFAULT_AMI_TMP}}
    [ $# -ge 1 ] && img="$1"
    [ -s "${img}" ] || error "bundle_ami: image file ${img} is invalid"
    local block_mappings="--block-device-mapping ami=sda1,root=/dev/sda1"
    local kernel_id=$(eval "echo \${EC2_DEFAULT_KERNEL_ID_${AMI_ARCH}}")
    local ramdisk_id=$(eval "echo \${EC2_DEFAULT_RAMDISK_ID_${AMI_ARCH}}")
    [ "i386" = "${AMI_ARCH}" ] && \
	block_mappings="${block_mappings},ephemeral0=sda2,swap=sda3"
    [ "x86_64" = "${AMI_ARCH}" ] && \
	block_mappings="${block_mappings},ephemeral0=sdb,ephemeral1=sdc"
ec2-bundle-image -k ${EC2_PRIVATE_KEY} \
	-c ${EC2_CERT} \
	-u $(echo "${EC2_USER_ID}" | tr -d '-') \
	-i "${img}" \
	-r ${AMI_ARCH} \
	${tmp:+"-d ${tmp}"} \
	${AMI_PREFIX:+"-p \"${AMI_PREFIX}\""} \
	${kernel_id:+"--kernel ${kernel_id}"} \
	${ramdisk_id:+"--ramdisk ${ramdisk_id}"} \
	${block_mappings}
}

# Upload and register AMIs to bucket $2, registered as name $3
upload_ami()
{
    local ami=
    local bucket=
    local name=
    local tmp=${AMI_TMP:-${DEFAULT_AMI_TMP}}
    [ $# -ge 1 ] && ami="$1"
    [ $# -ge 2 ] && bucket="$2"
    [ $# -ge 3 ] && name="$3"
    [ $# -ge 4 ] && description="$4"
    [ -z "${ami}" ] && error "upload_ami: \$ami is unspecified"
    [ -s "${tmp}/${ami}.manifest.xml" ] || \
	error "upload_ami: ${tmp}/${ami}.manifest.xml is empty or missing"
    [ -z "${bucket}" ] && error "upload_ami: \$bucket is unspecified"
    [ -z "${name}" ] && error "upload_ami: \$name is unspecified"
    [ -n "${name}" -a ${#name} -ge 3 -a ${#name} -le 128 ] || \
	error "upload_ami: name ${name} does not meet size requirements"
    [ -n "${description}" -a ${#description} -ge 1 -a ${#description} -le 255 ] || \
	error "upload_ami: description '${description}' does not meet size requirements"
    local acl=
    [ "public-read" = "${AMI_ACL}" -o "aws-exec-read" = "${AMI_ACL}" ] && \
	acl=${AMI_ACL}
    local kernel_id=$(eval "echo \${EC2_DEFAULT_KERNEL_ID_${AMI_ARCH}}")
    local ramdisk_id=$(eval "echo \${EC2_DEFAULT_RAMDISK_ID_${AMI_ARCH}}")
    ec2-upload-bundle -b ${bucket} \
	-m "${tmp}/${ami}.manifest.xml" \
	-a ${EC2_ACCESS_KEY} \
	-s ${EC2_SECRET_KEY} \
	${AMI_ACL:+"--acl ${AMI_ACL}"} \
	${tmp:+"-d ${tmp}"} \
	${AMI_PART:+"--part ${AMI_PART}"} \
	${AMI_LOCATION:+"--location ${AMI_LOCATION}"} \
	${AMI_URL:+"--url ${AMI_URL}"} \
	${AMI_RETRY:+"--retry ${AMI_RETRY}"} \
	${AMI_SKIPMANIFEST:+"--skipmanifest"} || \
	error "upload_ami: ec2-upload-bundle returned error code $?"
    ec2-register ${bucket}/${ami}.manifest.xml \
	${name:+"-n \"${name}\""} \
	${description:+"-d \"${description}\""} || \
	error "upload_ami: ec2-register returned error code $?"
}