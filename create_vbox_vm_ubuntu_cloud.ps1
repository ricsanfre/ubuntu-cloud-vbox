# Create VBOX Ubuntu VM from Ubuntu Cloud Image 
#
# Author: Ricardo Sanchez (ricsanfre@gmail.com)
# Script automate:
# - Img Download from Ubuntu website
# - Image conversion to VBox vdi format
# - Initial configuration through cloud-init
# - VM creation, configuration and startup

# Pre-requisites: Powershell 7.0
# Out-File command generate by default files in utf8NoBOM format (Compatible with cloud-init)
# PS 5 version Out-File does not generate files that are unix-compatible

# 

# Input pararmeters
param([Switch] $help, 
      [string] $base_path='.', 
      [string] $name='',
      [string] $ip='', 
      [int] $memory=1024,
      [int] $cores=1,
      [int] $disk=8192,
      [string] $vbox_bridged_adapter="Intel(R) Dual Band Wireless-AC 7265",
      [string] $vbox_host_only_adapter="VirtualBox Host-Only Ethernet Adapter"
      )

# Printing help message
if ( $help -or ( $name -eq '') -or ( $ip -eq '' ) )
{
  echo "Usage: "
  echo "> create_ubuntu_cloud_vbox_vm.ps1 -name <server_name>"
  echo "                                  -path <path>" 
  echo "                                  -ip <server_ip>"
  echo "                                  -memory <server_memory_MB>"
  secho "                                 -cores <cpu_cores>"
  echo "                                  -disk_size <server_disk_size_MB>"
  echo "                                  -vbox_bridged_adapter <bridged_if>"
  echo "                                  -vbox_host_only_adapter <hostonly_if>"
  echo "Mandatory parameters: <server_name> and <server-ip>. <server_ip> must belong to VBox HostOnly network"
  echo "VM will be created within a directory <path>/<name>. If a server already exists within that directory, VM is not created"
  echo "Default values: memory=1024 (1GB), disk_size=8192 (8GB)"
  echo "VM is created with two interfaces:"
  echo "  - NIC1 hostonly with static ip <server_ip>"
  echo "  - NIC2 bridgeadapter with dynamic ip, dhcp"
  echo "NOTE: VBOX interfaces adapter names might need to be adapted to your own environment"
  echo "      Modify within the script: vbox_bridged_adapter and vbox_host_only_adapter accordingly"
  exit
}

$script_base = $PSScriptRoot

$server_name=$name
$server_ip=$ip
$server_memory=$memory
$server_cores=$cores
$server_disk_size=$disk_size

$working_directory="${base_path}\${server_name}"
# Check if working directory already exists
if (Test-Path -Path $working_directory)
{
  echo "Server ${server_name} already exits within directory ${base_path}"
  exit
}

$userdata_template = ${server_name}
$network_template = ${server_name}

if ( -not (Test-Path -Path ${script_base}\templates\user-data-${userdata_template}.yml) )
{
  # If specific user-data template does not exit use default template
  $userdata_template = 'default'
}

if ( -not (Test-Path -Path ${script_base}\templates\network-config-${network_template}.yml) )
{
  # If specific network-config template does not exit use default template
  $network_template = 'default'
}

# Check cloud init templates exit: specific or default
if ( -not (Test-Path -Path ${script_base}\templates\user-data-${userdata_template}.yml) -or
    -not (Test-Path -Path ${script_base}\templates\network-config-${network_template}.yml) )
{
  echo "ERROR: Cloud init templates for ${server_name} do not exist in ${script_base}\templates"
  exit
}


# Check if configured adapters
echo "Checking VBOX interfaces adapters..."
$found_bridged_adapter=$false
$found_hostonly_adapter=$false

# Obtain configured hostonly and bridged adapter names
$vbox_bridgedifs = & "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" list bridgedifs | Select-String "^Name:" 

echo "Bridged Adapters:"
foreach ($if in $vbox_bridgedifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  # echo "${interface}"
  if ( $interface -eq $vbox_bridged_adapter )
  {
    $found_bridged_adapter=$true
  }
}
$vbox_hostonlyifs= & "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" list hostonlyifs | Select-String "^Name:"
echo "HostOnly Adapters:"
foreach ($if in $vbox_hostonlyifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  echo "${interface}"
  if ( $interface -eq $vbox_host_only_adapter )
  {
    $found_hostonly_adapter=$true
  }
}

if ( ( -not $found_bridged_adapter ) -or (-not $found_hostonly_adapter) )
{
  echo "Interfaces adapters not found in VBOX"
  echo "Please review your config"
  exit
}

$seed_directory_name="seed"
$seed_directory="${working_directory}\${seed_directory_name}"
## version for the image in numbers (14.04, 16.04, 18.04, etc.)
$ubuntuversion="20.04"
## image type: ova, vmdk, img, tar.gz
$imagetype="img"
$distro="ubuntu-${ubuntuversion}-server-cloudimg-amd64"
$img_dist="${distro}.${imagetype}"
$img_raw="${distro}.raw"
$img_vdi="${distro}.vdi"
$seed_iso="seed.iso"

## URL to most recent cloud image
$releases_url="https://cloud-images.ubuntu.com/releases/${ubuntuversion}/release"
$img_url="${releases_url}/${img_dist}"

# Step 1. Create working directory
echo "Creating Working directory ${working_directory}"
New-Item -Path ${base_path} -Name ${server_name} -ItemType "directory"

# Step 2. Move to working directory
echo "Moving to working directory ${working_directory}"
cd $working_directory

# Step 3 download Img. 
# Remove PS download progress bar to speed up the download

echo "Downloading image ${img_url}"
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $img_url -OutFile $img_dist

# Step 4. Convert the img to raw format using qemu
echo "Converting img to raw format"
& "C:\Program Files\qemu\qemu-img.exe" convert -O raw ${img_dist} ${img_raw}

# Step 5. Convert raw img to vdi
echo "Converting raw to vdi"
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" convertfromraw ${img_raw} ${img_vdi}

# Step 7. Enlarge vdi size
echo "Enlarging vdi to ${server_disk_size} MB"
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" modifyhd ${img_vdi} --resize ${server_disk_size}

# Step 8. Create seed directory with cloud-init config files
echo "Creating seed directory"
New-Item -Path ${working_directory} -Name ${seed_directory_name} -ItemType "directory"

echo "Creating cloud-init files"
# Create meta-data file
@"
instance-id: ubuntucloud-001
local-hostname: ${server_name}
"@ | Out-File -FilePath "${seed_directory}/meta-data" -Append

# Create user-data file

# Get template
$user_data = (Get-Content ${script_base}\templates\user-data-${userdata_template}.yml -Raw)
# Replace template variables
$user_data = $user_data -f $server_name
# Generate output file
$user_data | Out-File -FilePath "${seed_directory}/user-data" -Append


# Create network-config
# Get template
$network_config = (Get-Content ${script_base}\templates\network-config-${network_template}.yml -Raw)
# Replace template variables
$network_config = $network_config -f $server_ip
# Generate output file
$network_config | Out-File -FilePath "${seed_directory}/network-config" -Append


# Step 9. Create seed iso file
echo "Creating seed.iso"
& "C:\Program Files\CDBurnerXP\cdbxpcmd.exe" --burndata -folder:${seed_directory} -iso:${seed_iso} -format:iso -changefiledates -name:CIDATA

# Step 10. Create VM
echo "Creating VM ${server_name}"
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" createvm --name ${server_name} --register
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" modifyvm ${server_name} --cpus ${server_cores} --memory ${server_memory} --acpi on --nic1 hostonly --hostonlyadapter1 "${vbox_host_only_adapter}" --nic2 bridged --bridgeadapter2 "${vbox_bridged_adapter}"

# Enabling nested virtualization
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" modifyvm ${server_name} --nested-hw-virt on


# Adding SATA controler

& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" storagectl ${server_name} --name "SATA"  --add sata --controller IntelAhci --portcount 5
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" storagectl ${server_name} --name "IDE"  --add ide --controller PIIX4
# Adding vdi and iso
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" storageattach ${server_name} --storagectl "SATA" --port 0 --device 0 --type hdd --medium ${img_vdi}
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" storageattach ${server_name} --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium ${seed_iso}
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" modifyvm ${server_name} --boot1 disk --boot2 dvd --boot3 none --boot4 none 
# Enabling serial port
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" modifyvm ${server_name} --uart1 0x3F8 4 --uartmode1 server \\.\pipe\${server_name}


echo "Starting VM ${server_name}"
& "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe" startvm ${server_name}

echo "Cleaning..."
# Step 11. Deleting temporary files
Remove-Item -Path $seed_directory -Recurse -Force
Remove-Item $img_dist
Remove-Item $img_raw
echo "END."
