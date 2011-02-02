#! /bin/sh
#
# Create a custom AMI
#
KVM_SKIP_LAUNCH=${KVM_SKIP_LAUNCH:-""}
AMI_SKIP=${AMI_SKIP:-""}
AMI_SKIP_UPLOAD=${AMI_SKIP_UPLOAD:-""}
DEFAULT_AMI_BUCKET=${AMI_BUCKET:-"matthewemes.com/ami"}
DEFAULT_DISTRO=${DEFAULT_DISTRO:-debian}
DEFAULT_ARCH=${DEFAULT_ARCH:-$(uname -m)}
DEFAULT_CUSTOM=${DEFAULT_CUSTOM:-""}
DEFAULT_IMG_SIZE=${DEFAULT_IMG_SIZE:-$((1024 * 1024 * 1024))}
SUDO=${SUDO:-$(which sudo)}

# Use a random password for memes account; public key SSH only
MEMES_PASSWORD=${MEMES_PASSWORD:-$(dd if=/dev/urandom bs=1 count=8 | base64)}

# Use a random password for root; can be overridden by ENV or custom files
# remote access via public key SSH only
ROOT_PASSWORD=${ROOT_PASSWORD:-$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | base64 | tr -cd '[:alnum:]')}

# Source the common functions
SCRIPT_DIR=${SCRIPT_DIR:-$(dirname $0)}
[ -r "${SCRIPT_DIR}/ami_functions.sh" ] && . ${SCRIPT_DIR}/ami_functions.sh
type add_memes_keys >/dev/null 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$0: Error: required functions in ami_functions are not available" >&2
    exit 1
fi

# After execution remount /home without dev support and unbind shared systems
trap cleanup 0 1 2 3 15

# Print usage information
usage()
{
    echo "usage: $0 [-d|--distro distro] [-a|--arch arch] [-c|--customise custom]"
    echo "       where options are:-"
    echo "        -d distro, --distro distro  distribution to install"
    echo "           debian or centos, defaults to debian"
    echo "        -a arch, --arch arch  architecture of AMI"
    echo "           i386 or x86_64, defaults to architecture of current host"
    echo "        -c custom, --customise custom  include customisations in "
    echo "           custom file"
    echo
    exit 1
}

# Simple argument processor
getargs()
{
    local arg=
    [ $# -eq 0 ] && usage
    while [ -n "$1" ]; do
	case "$1" in
	    -d|--distro)
		shift
		distro="$1"
		[ "debian" = "${distro}" -o "centos" = "${distro}" ] || usage
		;;
	    -a|--arch)
		shift
		AMI_ARCH="$1"
		[ "i386" = "${AMI_ARCH}" -o "x86_64" = "${AMI_ARCH}" ] || usage
		;;
	    -c|--custom)
		shift
		custom="$1"
		[ -n "${custom}" ] || usage
		;;
	    *)
		usage;
		exit 1;
	esac
	shift
    done
}

# Handle script arguments and set to defaults if necessary
[ $# -ne 0 ] && getargs $@
[ -z "${distro}" ] && distro="${DEFAULT_DISTRO}"
[ -z "${AMI_ARCH}" ] && AMI_ARCH="${DEFAULT_ARCH}"

# Make sure environment is correct and ROOT_PKGS are specified
[ -n "${custom}" ] && prebuild_customise "${SCRIPT_DIR}" "${custom}"
[ -n "${distro}" ] && prebuild_distro "${SCRIPT_DIR}" "${distro}"
prebuild_validate
ec2_validate

base_dir=$(get_base_directory)
[ -z "${base_dir}" ] && error "need a valid base directory to continue"
is_ebs=$(is_ebs_volume "${base_dir}")

# If the base is not an EBS volume then treat like regular filesystem directory
if [ -z "${is_ebs}" ]; then
    # Get a mount point and prepare
    mount_point=$(get_img_mount_point)
    [ -z "${mount_point}" ] && \
	error "need a valid mount point to continue"
    rm_chroot "${base_dir}"
    mkdir -p "${base_dir}" || error "unable to create directory ${base_dir}"
fi

# Install the software in a chroot
prepare_base "${base_dir}"
prepare_chroot "${base_dir}"
post_chroot "${base_dir}"

# Handle common configuration scenarios
update_fstab "${base_dir}"
update_sshd "${base_dir}"
add_memes_keys "${base_dir}"
update_inittab "${base_dir}"

# Finalise any installation action
post_base "${base_dir}"

if [ -z "${is_ebs}" ]; then
    # Prepare a KVM instance for testing
    kvm_img=$(get_kvm_img_name)
    kvm_img_size=$(get_kvm_img_size)
    mk_disk_image "${kvm_img}" ${kvm_img_size}
    mount_img "${mount_point}"
    pre_kvm_image "${mount_point}"
    ${SUDO} rsync -avP "${base_dir}/" "${mount_point}/" || \
	error "rsync returned error code $? during copy of files to KVM image"
    post_kvm_image "${mount_point}"
    mk_bootable "${mount_point}"
    umount_img "${mount_point}"

    [ -z "${KVM_SKIP_LAUNCH}" ] && launch_img "${kvm_img}"
fi
[ -n "${AMI_SKIP}" ] && exit

if [ -z "${is_ebs}" ]; then
    # Create an AMI image
    ami_img=$(get_ami_img_name)
    ami_img_size=$(get_ami_img_size)
    mk_fs_image "${ami_img}" ${ami_img_size}
    mount_img "${mount_point}"
    pre_ami_image "${mount_point}"
    ${SUDO} rsync -avP "${base_dir}/" "${mount_point}/" || \
	error "rsync returned error code $? during copy of files to AMI image"
    pre_ami_image "${mount_point}"
    umount_img "${mount_point}"
    bundle_ami "${ami_img}"
    ami_name=$(get_ami_name)
    ami_description=$(get_ami_description)
    ami_bucket=$(get_ami_bucket)
    [ -z "${AMI_SKIP_UPLOAD}" ] && \
	upload_ami $(basename "${ami_img}") "${ami_bucket}" "${ami_name}" \
	"${ami_description}"
else
    # Complete the EBS setup
    echo
fi