#!/bin/sh 
[ "$BASH" ] && \
    export PS4='    +\t $BASH_SOURCE:$LINENO: ${FUNCNAME[0]:+${FUNCNAME[0]}():}'
######## CUSTOM SETTINGS #############

# modules to preload for the standalone grub
grub_modules=""
# name of configfile for grub to expect in mbusb.d/$distro
# .ref is automatically added to avoid self-sourcing via *.cfg
grub_standalone_config="refind-helper.cfg" 

# set the directory containing the iso's relative to the root of the USB device
# eg. /isos for /mnt/stick/isos/some.iso
# the default is multibootusb's setting /boot/isos
iso_dir="/boot/isos"

# change the location of the configfiles from multibootusb,
# relative to the root of the drive
# most of the time you can leave this unchanged
# Note, that this is relative to the /boot dir in the root of the device
mbusbd="/grub/mbusb.d"


### DON'T CHANGE STUFF BELOW THIS POINT ###
# Exit on errors and unbound variables
set -o nounset
set -o errexit

# Make sure only root can run this script
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" 1>&2
    echo "Trying with sudo now"
    exec sudo -k -- /bin/sh "$0" "$@" || cleanUp 2
fi

# Show usage
usage() {
    cat <<-EOF
        Usage: refind-multiboot-installer.sh [TARGET_DISK] eg. refind-multiboot-installer.sh /dev/sda1
        Install refind to a target drive and add a standalone efi bootloader for each iso file contained in the iso directory.

        device                      Device to install on
        -h, --help                  Display this message
        -s, --subdirectory <NAME>   Specify a data subdirectory (e.g. "boot" or "")

        Further options have to be edited in the CUSTOM section of this file.

        Note, that this script needs to be run as root.

EOF
}

# check for arguments 
parseArgs() {
    [ $# -eq 0 ] &&  usage && exit 0
    scriptname=$(basename "$0")
    data_subdir="/boot"
    esp_part="/dev/null"
    mbusb_part="/dev/null"
    use_extra_partition=false
    while [ "${#}" -gt 0 ]; do
        case "${1}" in
            # Show help
            -h|--help)
            showUsage
            exit 0
            ;;
        -m|--mbusb)
            # if esp differs from data partition, use this
            mbusb_part="${2}"
            export use_extra_partitio=true
            shift
            shift
            ;;
        -s|--subdirectory)
            data_subdir="${2}"
            shift
            shift
            ;;
        /dev/*)
            if [ -b "${1}" ]; then
                esp_part="${1}"
            else
                printf '%s: %s is not a valid device.\n' "${scriptname}" "${1}" >&2
                cleanUp 1
            fi
            shift
            ;;
        *)
            printf '%s: %s is not a valid argument.\n' "${scriptname}" "${1}" >&2
            cleanUp 1
            ;;
    esac
done
if [ "${mbusb_part}" = "/dev/null" ] ;then
    mbusb_part="${esp_part}"
    use_extra_partition=false
fi
}
# Confirm the device
confirmDevice() {
    printf 'Are you sure you want to use %s? [y/N] ' "${esp_part}"
    read -r answer1
    case "${answer1}" in
        [yY][eE][sS]|[yY])
            echo "Alright..."
            ;;
        *)
            cleanUp 3
            ;;
    esac
}

checkIfMounted() {
    mount="$(lsblk -r -no MOUNTPOINT "${1}")"
    name="${2}"
    is_mounted=false
    is_mounted_by_script=false
    [ -z "${mount}" ] || is_mounted=true

}

mountDevice() {
    name="${2}"
    device="${1}"
    mount="/tmp/""${name}"
    mkdir "${mount}"
    mount "${device}" "${mount}" && is_mounted=true
    is_mounted_by_script=true

}

checkRefindInstalled() {
    # check if refind.conf is there, so we may skip reinstalling
    if [ -f "${esp_mount}/efi/boot/refind.conf" ]; then
        echo "Refind is already installed. Skipping install."
        refind_installed=true
    else
        refind_installed=false
    fi
}

# Make an EFI file to load with rEFInd
makeEFIfile() {
    # needed for external grub.cfg to work
    grub_modules="${grub_modules} ""part_gpt part_msdos regexp all_video"
    # create embedded grub.cfg
    echo "configfile \${cmdpath}/${grub_standalone_config}" > /tmp/grub.cfg
    [ -d "${script_path}/refind" ] || mkdir "${script_path}/refind"

    grub-mkstandalone \
        -O x86_64-efi\
        -o "${script_path}/refind/iso.efi" \
        --modules="${grub_modules}" \
        --locales="en@quot" \
        --compress="xz" \
        "boot/grub/grub.cfg=/tmp/grub.cfg"
    rm /tmp/grub.cfg
    # ^ embed /tmp/grub.cfg into memdisk as (memdisk)/boot/grub/grub.cfg
}

# create an additional configfile, so rEFInd finds our new bootloaders
createRefindIsoConf() {
    configstring=""
    refind_path="${esp_mount}/efi/boot"

    # Populate a list of entries to be looked at by rEFInd
    for confd in "${mbusbd}"/*.d; do
        relative_path="$(realpath --relative-to "${esp_mount}" "${confd}")"
        configstring="${configstring},""${relative_path}"
    done

    # write our file
    cat <<-EOT > "${refind_path}""/refind-iso.conf"
    ### This file will be overwritten by refind-multiboot-installer.sh
    ### If you want to add to this list, do so in refind.conf

    # Set our custom folders to be looked at by rEFInd
    # The comma after the colon is intended and circumvents a bug in rEFInd, where the first entry of a list is ignored.
    also_scan_dirs +${mbusb_uuid}:${configstring} 
EOT

# Make rEFInd source our file
# Add line to config, if it isn't there yet
line="include refind-iso.conf"
if ! grep -qF "${line}" "${refind_path}""/refind.conf" ;then
    echo -e "### source the config file for booting ISO files\n""${line}" >> "${refind_path}""/refind.conf"
fi
}

copyFiles() {
    printf "Copying files to target"
    for isofile in "${mbusb_mount}${iso_dir}"/*; do
        # parse name of distro
        filename="$(basename "${isofile}")"
        distro="$(awk -v file="${filename}" 'BEGIN{FS="-"; $0=file; print tolower($1)}')"
        ## check for existing config folders
        if [ -d "${mbusbd}/${distro}.d" ]; then
            echo "creating config for ""${distro}" "in " "$(realpath "${isofile}" )"
           createConfig "${mbusbd}/${distro}.d/${grub_standalone_config}"           echo "copying..."
           cp -f "${script_path}""/refind/iso.efi" "${mbusbd}""/""${distro}"".d/""${distro}"".efi"

            ## add icons to be copied, if refind offers no auto-detection
            #  ^ todo
        fi
    done
}
# Create the file that loads another grub.cfg to display menuentries
createConfig() {
    tee <<EOT > "${1}"
## GRUB CFG file for ISO boot helper

seach --no-floppy --set=root --fs-uuid ${mbusb_uuid}
set isopath=$iso_dir
imgdevpath=\$root
export isopath imgdevpath

for configfile in \$cmdpath/*.cfg; do
    source \$configfile
done

EOT

}

cleanUp() {
    for part in esp mbusb; do
        look_at_bool="${part}""_is_mounted_by_script"
        look_at_path="${part}""_mount"
        if [ "${look_at_bool}" = true ]; then
            # unmount
            umount -f "${look_at_path}" 2>/dev/null || true
            # remove dirs
            [ -d "${look_at_path}" ] && rmdir "${look_at_path}"
        fi
    done
    if [ "${refind_installed}" ] && [ -d /tmp/refind_install ]; then
        # unmount
        umount -f /tmp/refind_install
        # remove dir
        rmdir /tmp/refind_install
    fi
    # exit
    exit "${1-0}"
}


###########################################################
####                       Main                        ####
###########################################################

# Trap kill signals (SIGHUP, SIGINT, SIGTERM) to do some cleanup and exit
trap "cleanUp" 1 2 15
grub_standalone_config="${grub_standalone_config}"".ref"
script_path="$(dirname "$(realpath "${0}")")"
refind_installed=false
# Get UUID of partition, where mbusb.d resides
# Parse the arguments given
parseArgs "${@}"
confirmDevice

# Mount the device and get mountpoint, set config directory
#is_mounted="$("basename ${partition}")""_is_mounted"
checkIfMounted "${esp_part}" "esp"
if [ "${is_mounted}" ] ; then
    esp_mount="${mount}"

else
    mountDevice "${esp_part}" "esp"
    esp_mount="/tmp/esp"
    export esp_mounted_by_script="${is_mounted_by_script}"
fi

if [ ${use_extra_partition} ] ; then
    checkIfMounted "${mbusb_part}" "mbusb"
    if [ "${is_mounted}" ] ; then
        mbusb_mount="${mount}"
    else
        mountDevice "${mbusb_part}" "mbusb"
        mbusb_mount="/tmp/mbusb"
        export mbusb_mounted_by_script="${is_mounted_by_script}"
    fi
fi
#[ "${mbusb_part_is_mounted}" = true ] || mount-device "${mbusb_part}" "mbusb"

mbusbd="${mbusb_mount}${data_subdir}${mbusbd}"
mbusb_uuid="$(lsblk -r -no UUID "${mbusb_part}")"

# If rEFInd is not installed, do it
checkRefindInstalled
[ "$refind_installed" = true ] || refind-install --usedefault "${esp_part}"
# Add config file to rEFInd
createRefindIsoConf

# Build the EFI file once
[ -e "${script_path}"/refind/iso.efi ] ||  makeEFIfile "${script_path}"/refind/iso.efi 

# Copy EFI file and config to target
copyFiles

# Clean up and exit
cleanUp
echo "All done."
# vim:  set tabstop=2: set shiftwith=2:
