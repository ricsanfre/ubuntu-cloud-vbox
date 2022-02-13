#!/bin/bash

usage() { 


    _usage="

    Usage: $(basename $0) [OPTIONS]

    Options:
    -n <server_name>
    -i <server_ip>
    -c <cpu_cores>
    -m <memory>
    -d <disk_size>
    -r <ubuntu_release>
    "

    echo "$_usage" 
    exit 1; 

}

# Default values

## version for the image in numbers (14.04, 16.04, 18.04, etc.)
ubuntuversion="20.04"
## Memory in MB
mem=1024
# Num of CPU-cores
cpu=1
# Disk size in MB
disk=8192

force_download="false"

vbox_bridged_adapter="wlp2s0"
vbox_host_only_adapter="vboxnet0"

while getopts ":n:p:i:c:m:d:r:f" o; do
    case "${o}" in
        n)
            name=${OPTARG}
            ;;
        p)
            path=${OPTARG}
            ;;
        i)
            ip=${OPTARG}
            ;;
        c)
            cpu=${OPTARG}
            ;;
        m)
            mem=${OPTARG}
            ;;
        d)
            disk=${OPTARG}
            ;;
        r)
            ubuntuversion=${OPTARG}
            ;;
        f)
            force_download="true"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))


# Printing help message
if [ -z "$name" ] | [ -z "$ip" ]
then
  usage
  exit
fi

# Parse script options

# SHORT=n:,p:,i::,c::,m::,d::,r::,h
# LONG=name:,path:,ip::,cores::,mem::,disk::,release::,help
# OPTS=$(getopt --options $SHORT --longoptions $LONG -- "$@")

# eval set -- "$OPTS"

# while [[ $# -gt 0 ]];
# do
#   case "$1" in
#     -n | --name )
#       name="$2"
#       shift 2
#       ;;
#     -p | --path )
#       path="$2"
#       shift 2
#       ;;
#     -i | --ip )
#       ip="$2"
#       shift 2
#       ;;
#     -c | --cores )
#       cpu="$2"
#       shift 2
#       ;;
#     -m | --mem )
#       mem="$2"
#       shift 2
#       ;;
#     -d | --disk )
#       disk="$2"
#       shift 2
#       ;;
#     -r | --release )
#       release="$2"
#       shift 2
#       ;;
#     -h | --help)
#       usage
#       exit 2
#       ;;
#     --)
#       shift;
#       break
#       ;;
#     *)
#       echo "Unexpected option: $1"
#       ;;
#   esac
# done

echo $name, $ip, $release, $cpu, $mem, $disk

# Absolute path to this script, e.g. /home/user/bin/foo.sh
SCRIPT=$(readlink -f "$0")
# Absolute path this script is in, thus /home/user/bin
script_base=$(dirname "$SCRIPT")


# Set working directory
WORKINGDIR="$path/$name"

echo $WORKINGDIR

# Check whether the server already exits in $path

if [[ -d "$WORKINGDIR" ]]
then
    echo "Server $name already exits within directory $path."
fi


# Setting cloud-init templates
userdata_template=$name
network_template=$name

# Set default cloud-init if there is not a template for the server name

if [[ ! -f "$script_base/templates/user-data-$userdata_template.yml" ]]
then
    userdata_template="default"
fi

if [[ ! -f "$script_base/templates/network-config-$network_template.yml" ]]
then
    network_template="default"
fi

# Check cloud init templates exit: specific or default
if [[ ! -f "$script_base/templates/user-data-$userdata_template.yml" ]] | [[ ! -f "$script_base/templates/network-config-$network_template.yml" ]] 
then
  
  echo "ERROR: Cloud init templates for $name do not exist in $script_base/templates"
  exit
fi

echo "Creating VM with the following parameters"
echo "- Ubuntu Release: $release"
echo "- Memory: $mem"
echo "- CPU Cores: $cpu"
echo "- Disk: $disk"
echo "- Cloud-init user-data template: user-data-$userdata_template.yml"
echo "- Cloud-init network-config template: network-config-$network_template.yml"
echo "- IP: $ip"


## image type: ova, vmdk, img, tar.gz
imagetype="img"

## URL to most recent cloud image
releases_url="https://cloud-images.ubuntu.com/releases/${ubuntuversion}/release"
img_url="${releases_url}/ubuntu-${ubuntuversion}-server-cloudimg-amd64.${imagetype}"

## download a cloud image to run, and convert it to virtualbox 'vdi' format
img_dist="${img_url##*/}"
img_raw="${img_dist%.img}.raw"
img_vdi="ubuntu-${ubuntuversion}-cloud-virtualbox.vdi"

echo $img_dist
# Step 3 download Img if not already downloaded or force download has been selected
img="$script_base/img/$img_dist"

if [ ! -f $img ] | [ $force_download == "true" ]
then
  echo "Downloading image ${img_url}"
  wget $img_url -O $img
fi

# Step 4. Convert the img to raw format using qemu. Requires qemu-utils package
qemu-img convert -O raw "${img}" "${img_raw}"

# Step 5. Convert raw img to vdi
vboxmanage convertfromraw "$img_raw" "$img_vdi"

# Step 7. Enlarge vdi size
echo "Enlarging vdi to $disk MB"
vboxmanage modifyhd $img_vdi --resize $disk


## Name the iso file for the cloud-config data
seed_iso="my-seed.iso"

## create meta-data file 
cat > meta-data <<EOF
instance-id: ubuntucloud-001
local-hostname: $name
EOF

# Create user_data file: Use template and replace variables
sed -e "s/{0}/$name/g" $script_base/templates/user-data-${userdata_template}.yml > user-data

# Create network-config file: Use template and replace variables
sed -e "s/{0}/$ip/g" $script_base/templates/network-config-$network_template.yml > network-config 

## Feed user-data and meta-data to the ISO seed / requieres cloud-image-utils package
cloud-localds --network-config network-config $seed_iso user-data meta-data

## create a virtual machine using vboxmanage

echo "Creating VM $name"
vboxmanage createvm --name $name --register

# Modify VM
vboxmanage modifyvm $name --cpus $cpu --memory $mem --acpi on --nic1 hostonly --hostonlyadapter1 $vbox_host_only_adapter --nic2 bridged --bridgeadapter2 $vbox_bridged_adapter

# Enabling nested virtualization
vboxmanage modifyvm $name --nested-hw-virt on

# Adding SATA controler

vboxmanage storagectl $name --name "SATA"  --add sata --controller IntelAhci --portcount 5
vboxmanage storagectl $name --name "IDE"  --add ide --controller PIIX4
# Adding vdi and iso
vboxmanage storageattach $name --storagectl "SATA" --port 0 --device 0 --type hdd --medium ${img_vdi}
vboxmanage storageattach $name --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium ${seed_iso}
vboxmanage modifyvm $name --boot1 disk --boot2 dvd --boot3 none --boot4 none
# Enabling serial port
# vboxmanage modifyvm $name --uart1 0x3F8 4 --uartmode1 server my.ttyS0

echo "Starting VM $name"
vboxmanage startvm $name