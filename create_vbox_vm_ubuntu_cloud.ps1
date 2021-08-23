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

# Input pararmeters
param([Switch] $help,
      [string] $base_path='.',
      [string] $name='',
      [string] $ip='',
      [int] $memory=1024,
      [int] $cores=1,
      [int] $disk_size=8192,
      [string] $ubuntuversion='20.04',
      [string] $vbox_bridged_adapter="Intel(R) Dual Band Wireless-AC 7265",
      [string] $vbox_host_only_adapter="VirtualBox Host-Only Ethernet Adapter",
      [string] $force_download='false'
      )

# Printing help message
if ( $help -or ( $name -eq '') -or ( $ip -eq '' ) )
{
  
@"

Script Usage:

create_vbox_vm_ubuntu_cloud.ps1 -name *server_name*
                                -path *path*
                                -ip *server_ip*
                                -cores *cpu_cores*
                                -memory *server_memory_MB*
                                -disk_size *server_disk_size_MB*
                                -ubuntuversion *ubuntu_release*
                                -vbox_bridged_adapter *bridged_if*
                                -vbox_host_only_adapter *hostonly_if*


Parameters:
- **name**: (M) server name. VM server name and hostname. (M)
- **ip**: (M) must belong to VBox HostOnly network
- **path**: (O) Base path used for creating the VM directory (default value: '.' current directory). A directory with name **name** is created in **path** directory. If a server already exists within that directory, VM is not created. 
- **memory**: (O) VM memory in MB (default value 1024, 1GB)
- **cores**: (O) VM cpu cores (default value 1)
- **disk_size** (O) VM disk size in MB (default value 8192, 8GB)
- **ubuntu_version** (O) Ubuntu relase 18.04, 20.04 (default value 20.04)
- **vbox_bridged_adapter** (O) and **vbox_host_only_adapter** (O): VBOX interfaces names
- **force_downloas** (O): Force download of img even when there is an existing image


VM is created with two interfaces:
- **NIC1** hostonly with static ip (server_ip)
- **NIC2** bridgeadapter with dynamic ip, dhcp

> NOTE: VBOX interfaces adapter names might need to be adapted to your own environment
> Commands for obtained VBOX configured interfaces
    vboxmanage list hostonlyifs
    vboxmanage list bridgedifs

The script will download img from ubuntu website if it is not available in **img** directory or *force_download* true parameter has been selected

The script will be use user-data and network-config templates located in **templates** directory named with *server_name* suffix:
- user-data-*server_name*.yml
- network-config-*server_name*.yml

If any of the files is missing the `default` files will be used.

Example execution:

```
create_vbox_vm_ubuntu_cloud.ps1 -name "server_name" -ip "192.168.56.201"
```


"@ | Show-Markdown
  
  exit
}

$script_base = $PSScriptRoot

# Exec files
$vboxmanage_exe = "C:\Program Files\Oracle\VirtualBox\vboxmanage.exe"
$qemu_img_exe = "C:\Program Files\qemu\qemu-img.exe"
$cdbxpcmd_exe = "C:\Program Files\CDBurnerXP\cdbxpcmd.exe"

# Getting Parameters
$server_name=$name
$server_ip=$ip
$server_memory=$memory
$server_cores=$cores
$server_disk_size=$disk_size

# Setting working directories
$working_directory="${base_path}\${server_name}"
# Check if working directory already exists
if (Test-Path -Path $working_directory)
{
  Write-Output "Server ${server_name} already exits within directory ${base_path}"
  exit
}

# Setting cloud-init templates
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
  Write-Output "ERROR: Cloud init templates for ${server_name} do not exist in ${script_base}\templates"
  exit
}

@"
Creating VM with the following parameters

  - Ubuntu Release: ${ubuntuversion}
  - Memory: ${server_memory}
  - CPU Cores: ${server_cores}
  - Disk: ${server_disk_size}
  - Cloud-init user-data template: user-data-${userdata_template}.yml
  - Cloud-init network-config template: network-config-${network_template}.yml
  - NIC1- HostOnlyAdapter: ${vbox_host_only_adapter}. IP: ${server_ip}
  - NIC2 - BridgedAdapter: ${vbox_bridged_adapter}
  
"@ | Write-Output

# Check if configured adapters
Write-Output "Checking VBOX interfaces adapters..."
$found_bridged_adapter=$false
$found_hostonly_adapter=$false

# Obtain configured hostonly and bridged adapter names
$vbox_bridgedifs = & ${vboxmanage_exe} list bridgedifs | Select-String "^Name:"

Write-Output "Bridged Adapters:"
foreach ($if in $vbox_bridgedifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  Write-Output "${interface}"
  if ( $interface -eq $vbox_bridged_adapter )
  {
    $found_bridged_adapter=$true
  }
}
$vbox_hostonlyifs= & ${vboxmanage_exe} list hostonlyifs | Select-String "^Name:"
Write-Output "HostOnly Adapters:"
foreach ($if in $vbox_hostonlyifs)
{
  $interface=$if.ToString().replace("Name:","").trim()
  Write-Output "${interface}"
  if ( $interface -eq $vbox_host_only_adapter )
  {
    $found_hostonly_adapter=$true
  }
}

if ( ( -not $found_bridged_adapter ) -or (-not $found_hostonly_adapter) )
{
  Write-Output "Interfaces adapters not found in VBOX"
  Write-Output "Please review your config"
  exit
}

$seed_directory_name="seed"
$seed_directory="${working_directory}\${seed_directory_name}"

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
Write-Output "Creating Working directory ${working_directory}"
New-Item -Path ${base_path} -Name ${server_name} -ItemType "directory"

# Step 2. Move to working directory
Write-Output "Moving to working directory ${working_directory}"
Set-Location $working_directory

$img = "${script_base}/img/${img_dist}"
# Step 3 download Img if not already downloaded or force download has been selected 
# Remove PS download progress bar to speed up the download

if ( -not (Test-Path -Path ${img} -PathType Leaf) -or ( ${force_download} -eq 'true' ) )
{
  Write-Output "Downloading image ${img_url}"
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $img_url -OutFile $img
}

# Step 4. Convert the img to raw format using qemu
Write-Output "Converting img to raw format"
& ${qemu_img_exe} convert -O raw ${img} ${img_raw}

# Step 5. Convert raw img to vdi
Write-Output "Converting raw to vdi"
& ${vboxmanage_exe} convertfromraw ${img_raw} ${img_vdi}

# Step 7. Enlarge vdi size
Write-Output "Enlarging vdi to ${server_disk_size} MB"
& ${vboxmanage_exe} modifyhd ${img_vdi} --resize ${server_disk_size}

# Step 8. Create seed directory with cloud-init config files
Write-Output "Creating seed directory"
New-Item -Path ${working_directory} -Name ${seed_directory_name} -ItemType "directory"

Write-Output "Creating cloud-init files"
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
Write-Output "Creating seed.iso"
& ${cdbxpcmd_exe} --burndata -folder:${seed_directory} -iso:${seed_iso} -format:iso -changefiledates -name:CIDATA

# Step 10. Create VM
Write-Output "Creating VM ${server_name}"
& ${vboxmanage_exe} createvm --name ${server_name} --register
& ${vboxmanage_exe} modifyvm ${server_name} --cpus ${server_cores} --memory ${server_memory} --acpi on --nic1 hostonly --hostonlyadapter1 "${vbox_host_only_adapter}" --nic2 bridged --bridgeadapter2 "${vbox_bridged_adapter}"

# Enabling nested virtualization
& ${vboxmanage_exe} modifyvm ${server_name} --nested-hw-virt on


# Adding SATA controler

& ${vboxmanage_exe} storagectl ${server_name} --name "SATA"  --add sata --controller IntelAhci --portcount 5
& ${vboxmanage_exe} storagectl ${server_name} --name "IDE"  --add ide --controller PIIX4
# Adding vdi and iso
& ${vboxmanage_exe} storageattach ${server_name} --storagectl "SATA" --port 0 --device 0 --type hdd --medium ${img_vdi}
& ${vboxmanage_exe} storageattach ${server_name} --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium ${seed_iso}
& ${vboxmanage_exe} modifyvm ${server_name} --boot1 disk --boot2 dvd --boot3 none --boot4 none
# Enabling serial port
& ${vboxmanage_exe} modifyvm ${server_name} --uart1 0x3F8 4 --uartmode1 server \\.\pipe\${server_name}


Write-Output "Starting VM ${server_name}"
& ${vboxmanage_exe} startvm ${server_name}

Write-Output "Cleaning..."
# Step 11. Deleting temporary files
Remove-Item -Path $seed_directory -Recurse -Force
# Remove-Item $img_dist
Remove-Item $img_raw
Write-Output "END."
