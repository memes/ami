# Implements the EBS flavour of AMI creation
#

# Perform initialisation steps for an EBS AMI
# - remove if necessary, then create a directory for the initial chroot files
flavour_initialise()
{
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && \
	error "flavour_initialise: \$base is unspecified"
}

# EBS AMI needs to be bundled, uploaded and registered with AWS to be used
flavour_do_ami()
{
    [ -n "${AMI_SKIP}" ] && \
	warn "flavour_do_ami: user requested skip of AMI registration; not recommended for EBS volumes" && \
	return 0
    local base=
    [ $# -ge 1 ] && base="$1"
    [ -z "${base}" ] && \
	error "flavour_do_ami: \$base is unspecified"
    [ -d "${base}" ] || \
	error "flavour_do_ami: ${base} is invalid"
    return 0
}