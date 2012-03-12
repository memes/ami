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
DEFAULT_FLAVOUR=${DEFAULT_FLAVOUR:-"s3"}
DEFAULT_IMG_SIZE=${DEFAULT_IMG_SIZE:-$((1024 * 1024 * 1024))}
DEFAULT_SYSTEM_TZ=${DEFAULT_SYSTEM_TZ:-"Etc/UTC"}
DEFAULT_USER_TZ=${DEFAULT_USER_TZ:-"America/Los_Angeles"}
SUDO=${SUDO:-$(which sudo)}

# Try to get a sane working directory from the user or environment, fallback to 
# ~/tmp
WORKINGDIR=${WORKINGDIR:-"$(readlink -e ${TMPDIR:-$TMP} 2>/dev/null)"}
[ -z "${WORKINGDIR}" ] && WORKINGDIR="$(readlink -e ~/tmp 2>/dev/null)"

# Use a random password for memes account; public key SSH only
MEMES_PASSWORD=${MEMES_PASSWORD:-$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | base64 | tr -cd '[:alnum:]')}

# Use a random password for root; can be overridden by ENV or custom files
# remote access via public key SSH only
ROOT_PASSWORD=${ROOT_PASSWORD:-$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | base64 | tr -cd '[:alnum:]')}

# Source the common functions
SCRIPT_DIR=${SCRIPT_DIR:-$(dirname $0)}
[ -r "${SCRIPT_DIR}/ami_functions.sh" ] && . ${SCRIPT_DIR}/ami_functions.sh
type error >/dev/null 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$0: Error: required functions in ami_functions are not available" >&2
    exit 1
fi

# After execution remount /home without dev support and unbind shared systems
trap cleanup 0 1 2 3 15

# Print usage information
usage()
{
    echo "usage: $0 [-d|--distro distro] [-a|--arch arch] [-c|--customise custom] [-f|--flavour flavour]"
    echo "       where options are:-"
    echo "        -d distro, --distro distro  distribution to install"
    echo "           centos, debian or oracle, defaults to ${DEFAULT_DISTRO}"
    echo "        -a arch, --arch arch  architecture of AMI"
    echo "           i386 or x86_64, defaults to architecture of current host"
    echo "        -c custom, --customise custom  include customisations in "
    echo "           custom file"
    echo "        -f flavour, --flavour flavour  build AMI using rules specified"
    echo "           by flavour file, defaults to ${DEFAULT_FLAVOUR}"
    echo "        -l, --launch, try to launch an image of the ami locally; will"
    echo "           reuse an existing image if present, or do a build without"
    echo "           uploading the ami"
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
		[ "debian" = "${distro}" -o "centos" = "${distro}" -o "oracle" = "${distro}" ] || usage
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
	    -f|--flavour)
		shift
		flavour="$1"
		[ "s3" = "${flavour}" -o "ebs" = "${flavour}" ] || usage
		;;
	    -l|--launch)
		AMI_SKIP=1
		USE_EXISTING=1
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
[ -z "${flavour}" ] && flavour="${DEFAULT_FLAVOUR}"
[ -z "${AMI_ARCH}" ] && AMI_ARCH="${DEFAULT_ARCH}"

# Make sure environment is correct and ROOT_PKGS are specified
[ -n "${custom}" ] && prebuild_custom "${SCRIPT_DIR}" "${custom}"
[ -n "${distro}" ] && prebuild_distro "${SCRIPT_DIR}" "${distro}"
[ -n "${flavour}" ] && prebuild_flavour "${SCRIPT_DIR}" "${flavour}"
prebuild_validate

# If a launch was requested, see if there is an existing image file ready to go
if [ -n "${USE_EXISTING}" ]; then
    img=$(get_kvm_img_name)
    if [ -z "${KVM_SKIP_LAUNCH}" -a -n "${img}" -a -e "${img}" ]; then
	launch_img "${img}"
	exit 1
    fi
fi

[ -z "${AMI_SKIP}" ] && ec2_validate

# Early initialisation of the system
base_dir=$(get_base_directory)
[ -z "${base_dir}" ] && error "need a valid base directory to continue"
initialise "${base_dir}"

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

# Perform KVM image creation and launch as flavour determines
do_kvm "${base_dir}"

# Perform AMI creation and registration, as flavour determines
do_ami "${base_dir}"

# Do any final actions specified by the scripts before cleanup and exit
finalise "${base_dir}"

# All done
exit 0