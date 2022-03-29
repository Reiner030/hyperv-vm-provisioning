<#
.SYNOPSIS
  Provision Cloud images on Hyper-V
.EXAMPLE
  PS C:\> .\New-HyperVCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 60GB -VMName "azure-1" -ImageVersion "20.04" -VirtualSwitchName "SW01" -VMGeneration 2
  PS C:\> .\New-HyperVCloudImageVM.ps1 -VMProcessorCount 2 -VMMemoryStartupBytes 2GB -VHDSizeBytes 8GB -VMName "debian11" -ImageVersion 11 -virtualSwitchName "External Switch" -VMGeneration 2 -GuestAdminUsername admin -GuestAdminPassword admin -VMMachine_StoragePath "D:\Hyper-V\" -NetAddress 192.168.188.12 -NetNetmask 255.255.255.0 -NetGateway 192.168.188.1 -NameServers "192.168.188.1"
  It should download cloud image and create VM, please be patient for first boot - it could take 10 minutes
  and requires network connection on VM
.NOTES
  Original script: https://blogs.msdn.microsoft.com/virtual_pc_guy/2015/06/23/building-a-daily-ubuntu-image-for-hyper-v/

  References:
  - https://git.launchpad.net/cloud-init/tree/cloudinit/sources/DataSourceAzure.py
  - https://github.com/Azure/azure-linux-extensions/blob/master/script/ovf-env.xml
  - https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
  - https://github.com/fdcastel/Hyper-V-Automation
  - https://bugs.launchpad.net/ubuntu/+source/walinuxagent/+bug/1700769
  - https://gist.github.com/Informatic/0b6b24374b54d09c77b9d25595cdbd47
  - https://www.neowin.net/news/canonical--microsoft-make-azure-tailored-linux-kernel/
  - https://www.altaro.com/hyper-v/powershell-script-change-advanced-settings-hyper-v-virtual-machines/

  Recommended: choco install putty -y
#>

#requires -Modules Hyper-V
#requires -RunAsAdministrator

[CmdletBinding()]
param(
  [string] $VMName = "CloudVm",
  [int] $VMGeneration = 1, # create gen1 hyper-v machine because of portability to Azure (https://docs.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image)
  [int] $VMProcessorCount = 1,
  [bool] $DynamicMemoryEnabled = $false,
  [uint64] $VMMemoryStartupBytes = 1024MB,
  [uint64] $MinimumBytes = $VMMemoryStartupBytes,
  [uint64] $MaximumBytes = $VMMemoryStartupBytes,
  [uint64] $VHDSizeBytes = 16GB,
  [string] $VirtualSwitchName = $null,
  [string] $VMVlanID = $null,
  [string] $VMNativeVlanID = $null,
  [string] $VMAllowedVlanIDList = $null,
  [string] $VMVersion = "8.0", # version 8.0 for hyper-v 2016 compatibility , check all possible values with Get-VMHostSupportedVersion
  [string] $VMHostname = $VMName,
  [string] $VMMachine_StoragePath = $null, # if defined setup machine path with storage path as subfolder
  [string] $VMMachinePath = $null, # if not defined here default Virtal Machine path is used
  [string] $VMStoragePath = $null, # if not defined here Hyper-V settings path / fallback path is set below
  [string] $DomainName = "domain.local",
  [string] $StaticMacAddress = $null,
  [string] $NetInterface = "eth0",
  [string] $NetAddress = $null,
  [string] $NetNetmask = $null,
  [string] $NetNetwork = $null,
  [string] $NetGateway = $null,
  [string] $NameServers = "1.1.1.1,1.0.0.1",
  [string] $NetConfigType = $null, # ENI, v1, v2, ENI-file, dhclient
  [string] $KeyboardLayout = "us",
  [string] $KeyboardModel = "pc105",
  [string] $KeyboardOptions = "compose:rwin",
  [string] $Locale = "en_US", # "en_US.UTF-8",
  [string] $TimeZone = "UTC", # UTC or continental zones of IANA DB like: Europe/Berlin
  [string] $CustomUserDataYamlFile,
  [string] $GuestAdminUsername = "user",
  [string] $GuestAdminPassword = "Passw0rd",
  [string] $ImageVersion = "20.04", # $ImageName ="focal" # 20.04 LTS , $ImageName="bionic" # 18.04 LTS
  [string] $ImageRelease = "release", # default option is get latest but could be fixed to some specific version for example "release-20210413"
  [string] $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases", # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
  [bool] $BaseImageCheckForUpdate = $true, # check for newer image at Distro cloud-images site
  [bool] $BaseImageCleanup = $true, # delete old vhd image. Set to false if using (TODO) differencing VHD
  [switch] $ShowSerialConsoleWindow = $false,
  [switch] $ShowVmConnectWindow = $false,
  [switch] $Force = $false
)

$NetAutoconfig = (($null -eq $NetAddress) -or ($NetAddress -eq "")) -and
                 (($null -eq $NetNetmask) -or ($NetNetmask -eq "")) -and
                 (($null -eq $NetNetwork) -or ($NetNetwork -eq "")) -and
                 (($null -eq $NetGateway) -or ($NetGateway -eq "")) -and
                 (($null -eq $StaticMacAddress) -or ($StaticMacAddress -eq ""))

if ($NetAutoconfig -eq $false) {
  Write-Verbose "Given Network configuration - no checks done in script:"
  Write-Verbose "StaticMacAddress: '$StaticMacAddress'"
  Write-Verbose "NetInterface:     '$NetInterface'"
  Write-Verbose "NetAddress:       '$NetAddress'"
  Write-Verbose "NetNetmask:       '$NetNetmask'"
  Write-Verbose "NetNetwork:       '$NetNetwork'"
  Write-Verbose "NetGateway:       '$NetGateway'"
  Write-Verbose ""
}

# default error action
$ErrorActionPreference = 'Stop'

# pwsh (powershell core): try to load module hyper-v
if ($psversiontable.psversion.Major -ge 6) {
  Import-Module hyper-v -SkipEditionCheck
}

# check if verbose is present, src: https://stackoverflow.com/a/25491281/1155121
$verbose = $VerbosePreference -ne 'SilentlyContinue'

# check if running hyper-v host version 8.0 or later
# Get-VMHostSupportedVersion https://docs.microsoft.com/en-us/powershell/module/hyper-v/get-vmhostsupportedversion?view=win10-ps
# or use vmms version: $vmms = Get-Command vmms.exe , $vmms.version. src: https://social.technet.microsoft.com/Forums/en-US/dce2a4ec-10de-4eba-a19d-ae5213a2382d/how-to-tell-version-of-hyperv-installed?forum=winserverhyperv
$vmms = Get-Command vmms.exe
if (([System.Version]$vmms.fileversioninfo.productversion).Major -lt 10) {
  throw "Unsupported Hyper-V version. Minimum supported version for is Hyper-V 2016."
}

# Helper function for no error file cleanup
function cleanupFile ([string]$file) {
  if (test-path $file) {
    Remove-Item $file -force
  }
}

$FQDN = $VMHostname.ToLower() + "." + $DomainName.ToLower()
# Instead of GUID, use 26 digit machine id suitable for BIOS serial number
# src: https://stackoverflow.com/a/67077483/1155121
# $vmMachineId = [Guid]::NewGuid().ToString()
$VmMachineId = "{0:####-####-####-####}-{1:####-####-##}" -f (Get-Random -Minimum 1000000000000000 -Maximum 9999999999999999),(Get-Random -Minimum 1000000000 -Maximum 9999999999)
$tempPath = [System.IO.Path]::GetTempPath() + $vmMachineId
mkdir -Path $tempPath | out-null
Write-Verbose "Using temp path: $tempPath"

# ADK Download - https://www.microsoft.com/en-us/download/confirmation.aspx?id=39982
# You only need to install the deployment tools, src2: https://github.com/Studisys/Bootable-Windows-ISO-Creator
#$oscdimgPath = "C:\Program Files (x86)\Windows Kits\8.1\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
$oscdimgPath = Join-Path $PSScriptRoot "tools\oscdimg\x64\oscdimg.exe"

# Download qemu-img from here: http://www.cloudbase.it/qemu-img-windows/
$qemuImgPath = Join-Path $PSScriptRoot "tools\qemu-img\qemu-img.exe"

# Windows version of tar for extracting tar.gz files, src: https://github.com/libarchive/libarchive
$bsdtarPath = Join-Path $PSScriptRoot "tools\bsdtar.exe"

# Update this to the release of Image that you want
Switch ($ImageVersion) {
  "18.04" {
    $_ = "bionic"
    $ImageVersion = "18.04"
  }
  "bionic" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "bionic"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud-images.ubuntu.com/releases/bionic/release/ubuntu-18.04-server-cloudimg-amd64-azure.vhd.zip
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersion/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64-azure"
    $ImageFileExtension = "vhd.tar.gz"
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "vhd.manifest"
  }
  "20.04" {
    $_ = "focal"
    $ImageVersion = "20.04"
  }
  "focal" {
    $ImageOS = "ubuntu"
    $ImageVersionName = "focal"
    $ImageRelease = "release" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64-azure.vhd.zip
    $ImageBaseUrl = "http://cloud-images.ubuntu.com/releases" # alternative https://mirror.scaleuptech.com/ubuntu-cloud-images/releases
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersion/$ImageRelease/" # latest
    $ImageFileName = "$ImageOS-$ImageVersion-server-cloudimg-amd64-azure" # should contain "vhd.*" version
    $ImageFileExtension = "vhd.zip" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA256SUMS"
    $ImageManifestSuffix = "vhd.manifest"
  }
  "10" {
    $_ = "buster"
    $ImageVersion = "10"
  }
  "buster" {
    $ImageOS = "debian"
    $ImageVersionName = "buster"
    $ImageRelease = "latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/buster/latest/debian-10-azure-amd64.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    $ImageFileName = "$ImageOS-$ImageVersion-azure-amd64" # should contain "vhd.*" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  "11" {
    $_ = "bullseye"
    $ImageVersion = "11"
  }
  "bullseye" {
    $ImageOS = "debian"
    $ImageVersionName = "bullseye"
    $ImageRelease = "latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/bullseye/latest/debian-11-azure-amd64.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    $ImageFileName = "$ImageOS-$ImageVersion-azure-amd64" # should contain "raw" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  "testing" {
    $_ = "sid"
    $ImageVersion = "sid"
  }
  "sid" {
    $ImageOS = "debian"
    $ImageVersionName = "sid"
    $ImageRelease = "daily/latest" # default option is get latest but could be fixed to some specific version for example "release-20210413"
    # http://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-azure-amd64-daily.tar.xz
    $ImageBaseUrl = "http://cloud.debian.org/images/cloud"
    $ImageUrlRoot = "$ImageBaseUrl/$ImageVersionName/$ImageRelease/"
    #$ImageFileName = "$ImageOS-$ImageVersion-nocloud-amd64" # should contain "raw" version
    $ImageFileName = "$ImageOS-$ImageVersion-azure-amd64-daily" # should contain "raw" version
    $ImageFileExtension = "tar.xz" # or "vhd.tar.gz" on older releases
    # Manifest file is used for version check based on last modified HTTP header
    $ImageHashFileName = "SHA512SUMS"
    $ImageManifestSuffix = "json"
  }
  default {throw "Image version $ImageVersion not supported."}
}

$ImagePath = "$($ImageUrlRoot)$($ImageFileName)"
$ImageHashPath = "$($ImageUrlRoot)$($ImageHashFileName)"

if ($null -ne $VMMachine_StoragePath) {
  $VMMachinePath = $VMMachine_StoragePath
  $VMStoragePath = "$VMMachine_StoragePath\$VMName\Virtual Hard Disks"
}

# Get default Virtual Machine path (requires administrative privileges)
if (-not $VMMachinePath) {
  $vmms = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
  $vmmsSettings = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
  $VMMachinePath = $vmmsSettings.DefaultVirtualMachinePath
  # fallback
  if (-not $VMMachinePath) {
    $VMMachinePath = "C:\ProgramData\Microsoft\Windows\Hyper-V"
  }
}
if (!(test-path $VMMachinePath)) {mkdir -Path $VMMachinePath | out-null}

# Get default Virtual Hard Disk path (requires administrative privileges)
if (-not $VMStoragePath) {
  $vmms = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
  $vmmsSettings = Get-WmiObject -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
  $VMStoragePath = $vmmsSettings.DefaultVirtualHardDiskPath
  # fallback
  if (-not $VMStoragePath) {
    $VMStoragePath = "C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks"
  }
}
if (!(test-path $VMStoragePath)) {mkdir -Path $VMStoragePath | out-null}

# storage location for base images
$ImageCachePath = Join-Path $PSScriptRoot $(".\cache\CloudImage-$ImageOS-$ImageVersion")
if (!(test-path $ImageCachePath)) {mkdir -Path $ImageCachePath | out-null}

# Get the timestamp of the latest build on the cloud-images site
$BaseImageStampFile = join-path $ImageCachePath "baseimagetimestamp.txt"
[string]$stamp = ''
if (test-path $BaseImageStampFile) {
  $stamp = (Get-Content -Path $BaseImageStampFile | Out-String).Trim()
  Write-Verbose "Timestamp from cache: $stamp"
}
if ($BaseImageCheckForUpdate -or ($stamp -eq '')) {
  $stamp = (Invoke-WebRequest -UseBasicParsing "$($ImagePath).$($ImageManifestSuffix)").BaseResponse.LastModified.ToUniversalTime().ToString("yyyyMMddHHmmss")
  Set-Content -path $BaseImageStampFile -value $stamp -force
  Write-Verbose "Timestamp from web (new): $stamp"
}

# Delete the VM if it is around
$vm = Get-VM -VMName $VMName -ErrorAction 'SilentlyContinue'
if ($vm) {
  & .\Cleanup-VM.ps1 $VMName -Force:$Force
}

# There is a documentation failure not mention needed dsmode setting:
# https://gist.github.com/Informatic/0b6b24374b54d09c77b9d25595cdbd47
# Only in special cloud environments its documented already:
# https://cloudinit.readthedocs.io/en/latest/topics/datasources/cloudsigma.html
# metadata for cloud-init
$metadata = @"
dsmode: local
instance-id: $($VmMachineId)
local-hostname: $($VMHostname)
"@

Write-Verbose "Metadata:"
Write-Verbose $metadata
Write-Verbose ""

# Azure:   https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
# NoCloud: https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
# with static network examples included

if ($NetAutoconfig -eq $false) {
  Write-Verbose "Network Autoconfiguration disabled."
  #$NetConfigType = "v1"
  #$NetConfigType = "v2"
  #$NetConfigType = "ENI"
  #$NetConfigType = "ENI-file" ## needed for Debian
  if ($ImageOS -eq "debian") {
    Write-Verbose "OS 'Debian' found; manual network configuration 'ENI-file' activated."
    $NetConfigType = "ENI-file"
  }
  #$NetConfigType = "dhclient"
  if ($null -eq $NetConfigType) {
    Write-Verbose "No special OS found; usind default manual network configuration 'ENI-file'."
    $NetConfigType = "ENI-file"
  } else {
    Write-Verbose "NetworkConfigType: '$NetConfigType' assigned."
  }
}
$networkconfig = $null
if ($NetAutoconfig -eq $false) {
  Write-Verbose "Network autoconfig disabled; preparing networkconfig."
  if ($NetConfigType -ieq "v1") {
    Write-Verbose "v1 requested ..."
    $networkconfig = @"
## /network-config on NoCloud cidata disk
## version 1 format
## version 2 is completely different, see the docs
## version 2 is not supported by Fedora
---
version: 1
config:
  - enabled
  - type: physical
    name: $NetInterface
    $(if (($null -eq $StaticMacAddress) -or ($StaticMacAddress -eq "")) { "#" })mac_address: $StaticMacAddress
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })subnets:
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })  - type: static
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })    address: $NetAddress
    $(if (($null -eq $NetNetmask) -or ($NetNetmask -eq "")) { "#" })    netmask: $NetNetmask
    $(if (($null -eq $NetNetwork) -or ($NetNetwork -eq "")) { "#" })    network: $NetNetwork
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })    routes:
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })      - network: 0.0.0.0
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })        netmask: 0.0.0.0
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })        gateway: $NetGateway
  - type: nameserver
    address: ['$($NameServers.Split(",") -join "', '" )']
    search:  ['$($DomainName)']
"@
} elseif ($NetConfigType -ieq "v2") {
    Write-Verbose "v2 requested ..."
    $networkconfig = @"
version: 2
config: enabled
ethernets:
  $($NetInterface):
    dhcp: $NetAutoconfig
    #$(if (($null -eq $StaticMacAddress) -or ($StaticMacAddress -eq "")) { "#" })mac_address: $StaticMacAddress
    $(if (($null -eq $NetAddress) -or ($NetAddress -eq "")) { "#" })addresses: $NetAddress
    $(if (($null -eq $NetGateway) -or ($NetGateway -eq "")) { "#" })gateway4: $NetGateway
    nameservers:
      addresses: ['$($NameServers.Split(",") -join "', '" )']
      search: ['$($DomainName)']
"@
  } elseif ($NetConfigType -ieq "ENI") {
    Write-Verbose "ENI requested ..."
    $networkconfig = @"
# inline-ENI network configuration
network-interfaces: |
  iface $NetInterface inet static
$(if (($null -ne $StaticMacAddress) -and ($StaticMacAddress -ne "")) { "  hwaddress ether $StaticMacAddress`n"
})$(if (($null -ne $NetAddress) -and ($NetAddress -ne "")) { "  address $NetAddress`n"
})$(if (($null -ne $NetNetwork) -and ($NetNetwork -ne "")) { "  network $NetNetwork`n"
})$(if (($null -ne $NetNetmask) -and ($NetNetmask -ne "")) { "  netmask $NetNetmask`n"
})$(if (($null -ne $NetBroadcast) -and ($NetBroadcast -ne "")) { "  broadcast $Broadcast`n"
})$(if (($null -ne $NetGateway) -and ($NetGateway -ne "")) { "  gateway $NetGateway`n"
})
  dns-nameservers $($NameServers.Split(",") -join " ")
  dns-search $DomainName
"@
  } elseif ($NetConfigType -ieq "ENI-file") {
    Write-Verbose "ENI-file requested ..."
    # direct network configuration setup
    $networkconfig = @"
# Static IP address
write_files:
  - content: |
      # Configuration file for ENI networkmanager
      # This file describes the network interfaces available on your system
      # and how to activate them. For more information, see interfaces(5).

      source /etc/network/interfaces.d/*

      # The loopback network interface
      auto lo
      iface lo inet loopback

      # The primary network interface
      allow-hotplug eth0
      iface $NetInterface inet static
$(if (($null -ne $NetAddress) -and ($NetAddress -ne "")) { "          address $NetAddress`n"
})$(if (($null -ne $NetNetwork) -and ($NetNetwork -ne "")) { "          network $NetNetwork`n"
})$(if (($null -ne $NetNetmask) -and ($NetNetmask -ne "")) { "          netmask $NetNetmask`n"
})$(if (($null -ne $NetBroadcast) -and ($NetBroadcast -ne "")) { "          broadcast $Broadcast`n"
})$(if (($null -ne $NetGateway) -and ($NetGateway -ne "")) { "          gateway $NetGateway`n"
})$(if (($null -ne $StaticMacAddress) -and ($StaticMacAddress -ne "")) { "      hwaddress ether $StaticMacAddress`n"
})
          dns-nameservers $($NameServers.Split(",") -join " ")
          dns-search $DomainName
    path: /etc/network/interfaces.d/$($NetInterface)
"@
  } elseif ($NetConfigType -ieq "dhclient") {
    Write-Verbose "dhclient requested ..."
    $networkconfig = @"
# Static IP address
write_files:
  - content: |
      Touch file to disable sshd restart while doing cloud-init
    path: /etc/ssh/sshd_not_to_be_run
  - content: |
      # Configuration file for /sbin/dhclient.
      send host-name = gethostname();
      lease {
        interface `"$NetInterface`";
        fixed-address $NetAddress;
        option host-name `"$($FQDN)`";
        option subnet-mask $NetAddress
        #option broadcast-address 192.33.137.255;
        option routers $NetGateway;
        option domain-name-servers $($NameServers.Split(",") -join " ");
        renew 2 2022/1/1 00:00:01;
        rebind 2 2022/1/1 00:00:01;
        expire 2 2022/1/1 00:00:01;
      }

      # Generate Stable Private IPv6 Addresses instead of hardware based ones
      slaac private

    path: /etc/dhcp/dhclient.conf
"@
  } else {
    Write-Warning "No network configuration version type defined for static IP address setup."
  }
}

if ($null -ne $networkconfig) {
  Write-Verbose ""
  Write-Verbose "Network-Config:"
  Write-Verbose $networkconfig
  Write-Verbose ""
}

# userdata for cloud-init, https://cloudinit.readthedocs.io/en/latest/topics/examples.html
$userdata = @"
#cloud-config
# vim: syntax=yaml
# created: $(Get-Date -UFormat "%a %b/%d/%Y %T %Z")

hostname: $($VMHostname)
fqdn: $($FQDN)
# cloud-init Bug 21.4.1: locale update prepends "LANG=" like in
# /etc/defaults/locale set and results into error
#locale: $Locale
timezone: $TimeZone

growpart:
  mode: auto
  devices: [/]
  ignore_growroot_disabled: false

apt_preserve_sources_list: true
package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - hyperv-daemons
  - eject
  - console-setup
  - keyboard-configuration

# documented keyboard option, but not implemented ?
keyboard:
  layout: $KeyboardLayout
  model: $KeyboardModel
  variant: $KeyboardVariant
  options: $KeyboardOptions

system_info:
  default_user:
    name: $($GuestAdminUsername)

password: $($GuestAdminPassword)
chpasswd: { expire: false }
ssh_pwauth: true

#ssh_authorized_keys:
#  - ssh-rsa AAAAB... comment

# bootcmd can be setup like runcmd but would run at very early stage
# on every cloud-init assisted boot if not prepended by command "cloud-init-per":
#bootcmd:
  # - [ cloud-init-per, sh, -c, echo "127.0.0.1 localhost" >> /etc/hosts ]
runcmd:
  # - [ sh, -c, echo "127.0.0.1 localhost" >> /etc/hosts ]
  # force password change on 1st boot
  # - [ chage, -d, 0, $($GuestAdminUsername) ]
  # remove metadata iso
  - [ sh, -c, "if test -b /dev/cdrom; then eject; fi" ]
  - [ sh, -c, "if test -b /dev/sr0; then eject /dev/sr0; fi" ]
$(if ($ImageFileName.Contains("azure")) { "
    # dont start waagent service since it useful only for azure/scvmm
  - [ systemctl, disable, walinuxagent.service]
"})  # disable cloud init on next boot (https://cloudinit.readthedocs.io/en/latest/topics/boot.html, https://askubuntu.com/a/1047618)
  - [ sh, -c, touch /etc/cloud/cloud-init.disabled ]
  # set locale
  # cloud-init Bug 21.4.1: locale update prepends "LANG=" like in
  # /etc/defaults/locale set and results into error
  - [ locale-gen, "$($Locale).UTF-8" ]
  - [ update-locale, "$($Locale).UTF-8" ]
  # documented keyboard option, but not implemented ?
  # change keyboard layout, src: https://askubuntu.com/a/784816
  - [ sh, -c, sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'$($KeyboardLayout)'\"/g' /etc/default/keyboard ]
  # Reactivate OpenSSH for further boots
  - rm -f /etc/ssh/sshd_not_to_be_run
$(if (($NetAutoconfig -eq $false) -and ($NetConfigType -ieq "ENI-file")) {
  "  # Comment out cloud-init based dhcp configuration for $NetInterface
  - sed  -e 's/^/#/' -i /etc/network/interfaces.d/50-cloud-init"
})

$(if (($NetAutoconfig -eq $false) -and (($NetConfigType -ieq "ENI") -or
                                        ($NetConfigType -ieq "ENI-file") -or
                                        ($NetConfigType -ieq "dhclient"))) { $networkconfig
})
manage_etc_hosts: true
manage_resolv_conf: true

resolv_conf:
$(if ($NameServers.Contains("1.1.1.1")) { "  # cloudflare dns, src: https://1.1.1.1/dns/" }
)  nameservers: ['$( $NameServers.Split(",") -join "', '" )']
  searchdomains:
    - $($DomainName)
  domain: $($DomainName)

power_state:
  mode: reboot
  message: Provisioning finished, rebooting ...
  timeout: 15
"@

Write-Verbose "Userdata:"
Write-Verbose $userdata
Write-Verbose ""

# override default userdata with custom yaml file: $CustomUserDataYamlFile
# the will be parsed for any powershell variables, src: https://deadroot.info/scripts/2018/09/04/PowerShell-Templating
if (-not [string]::IsNullOrEmpty($CustomUserDataYamlFile) -and (Test-Path $CustomUserDataYamlFile)) {
  Write-Verbose "Using custom userdata yaml $CustomUserDataYamlFile"
  $userdata = $ExecutionContext.InvokeCommand.ExpandString( $(Get-Content $CustomUserDataYamlFile -Raw) ) # parse variables
}

# cloud-init configuration that will be merged, see https://cloudinit.readthedocs.io/en/latest/topics/datasources/azure.html
$dscfg = @"
datasource:
 Azure:
  agent_command: ["/bin/systemctl", "disable walinuxagent.service"]
# agent_command: __builtin__
  apply_network_config: false
#  data_dir: /var/lib/waagent
#  dhclient_lease_file: /var/lib/dhcp/dhclient.eth0.leases
#  disk_aliases:
#      ephemeral0: /dev/disk/cloud/azure_resource
#  hostname_bounce:
#      interface: eth0
#      command: builtin
#      policy: true
#      hostname_command: hostname
  set_hostname: false
"@

# src https://github.com/Azure/WALinuxAgent/blob/develop/tests/data/ovf-env.xml
$ovfenvxml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:oe="http://schemas.dmtf.org/ovf/environment/1" xmlns:wa="http://schemas.microsoft.com/windowsazure" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <wa:ProvisioningSection>
   <wa:Version>1.0</wa:Version>
   <LinuxProvisioningConfigurationSet
      xmlns="http://schemas.microsoft.com/windowsazure"
      xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
    <ConfigurationSetType>LinuxProvisioningConfiguration</ConfigurationSetType>
    <HostName>$($VMHostname)</HostName>
    <UserName>$($GuestAdminUsername)</UserName>
    <UserPassword>$($GuestAdminPassword)</UserPassword>
    <DisableSshPasswordAuthentication>false</DisableSshPasswordAuthentication>
    <CustomData>$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userdata)))</CustomData>
    <dscfg>$([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dscfg)))</dscfg>
    <!-- TODO add ssh key provisioning support -->
    <!--
        <SSH>
          <PublicKeys>
            <PublicKey>
              <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
              <Path>$HOME/UserName/.ssh/authorized_keys</Path>
              <Value>ssh-rsa AAAANOTAREALKEY== foo@bar.local</Value>
            </PublicKey>
          </PublicKeys>
          <KeyPairs>
            <KeyPair>
              <Fingerprint>EB0C0AB4B2D5FC35F2F0658D19F44C8283E2DD62</Fingerprint>
              <Path>$HOME/UserName/.ssh/id_rsa</Path>
            </KeyPair>
          </KeyPairs>
        </SSH>
    -->
    </LinuxProvisioningConfigurationSet>
  </wa:ProvisioningSection>
  <!--
  <wa:PlatformSettingsSection>
		<wa:Version>1.0</wa:Version>
		<wa:PlatformSettings>
			<wa:KmsServerHostname>kms.core.windows.net</wa:KmsServerHostname>
			<wa:ProvisionGuestAgent>false</wa:ProvisionGuestAgent>
			<wa:GuestAgentPackageName xsi:nil="true"/>
			<wa:RetainWindowsPEPassInUnattend>true</wa:RetainWindowsPEPassInUnattend>
			<wa:RetainOfflineServicingPassInUnattend>true</wa:RetainOfflineServicingPassInUnattend>
			<wa:PreprovisionedVm>false</wa:PreprovisionedVm>
		</wa:PlatformSettings>
	</wa:PlatformSettingsSection>
  -->
 </Environment>
"@

# Make temp location for iso image
mkdir -Path "$($tempPath)\Bits"  | out-null

# Output metadata, networkconfig and userdata to file on disk
Set-Content "$($tempPath)\Bits\meta-data" ([byte[]][char[]] "$metadata") -Encoding Byte
if (($NetAutoconfig -eq $false) -and
   (($NetConfigType -ieq "v1") -or ($NetConfigType -ieq "v2"))) {
  Set-Content "$($tempPath)\Bits\network-config" ([byte[]][char[]] "$networkconfig") -Encoding Byte
}
Set-Content "$($tempPath)\Bits\user-data" ([byte[]][char[]] "$userdata") -Encoding Byte
$ovfenvxml.Save("$($tempPath)\Bits\ovf-env.xml");

# Create meta data ISO image, src: https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html
#,"-u1","-udfver200"
#& $oscdimgPath "$($tempPath)\Bits" "$($metaDataIso).2.iso" -u2 -udfver200
Write-Host "Creating metadata iso for VM provisioning..." -NoNewline
$metaDataIso = "$($VMStoragePath)\$($VMName)-metadata.iso"
Write-Verbose "Filename: $metaDataIso"
cleanupFile $metaDataIso
<# azure #>
Start-Process `
	-FilePath $oscdimgPath `
  -ArgumentList  "`"$($tempPath)\Bits`"","`"$metaDataIso`"","-u2","-udfver200" `
	-Wait -NoNewWindow `
	-RedirectStandardOutput "$($tempPath)\oscdimg.log" `
  -RedirectStandardError "$($tempPath)\oscdimg-error.log"

<# NoCloud
Start-Process `
	-FilePath $oscdimgPath `
  -ArgumentList  "`"$($tempPath)\Bits`"","`"$metaDataIso`"","-lCIDATA","-d","-n" `
	-Wait -NoNewWindow `
	-RedirectStandardOutput "$($tempPath)\oscdimg.log"
#>
if (!(test-path "$metaDataIso")) {throw "Error creating metadata iso"}
Write-Verbose "Metadata iso written"
Write-Host -ForegroundColor Green " Done."


# check if local cached cloud image is the most recent one
if (!(test-path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)")) {
  try {
    # If we do not have a matching image - delete the old ones and download the new one
    Write-Host 'Removing old images from cache...' -NoNewline
    Remove-Item "$($ImageCachePath)\$($ImageOS)-*.vhd*"
    Write-Host -ForegroundColor Green " Done."

    # get headers for content length
    Write-Host 'Check new image size ...' -NoNewline
    $response = Invoke-WebRequest "$($ImagePath).$($ImageFileExtension)" -UseBasicParsing -Method Head
    $downloadSize = [int]$response.Headers["Content-Length"]
    Write-Host -ForegroundColor Green " Done."

    Write-Host "Downloading new Cloud image ($([int]($downloadSize / 1024 / 1024)) MB)..." -NoNewline
    Write-Verbose $(Get-Date)
    # download new image
    Invoke-WebRequest "$($ImagePath).$($ImageFileExtension)" -OutFile "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension).tmp" -UseBasicParsing
    # rename from .tmp to $($ImageFileExtension)
    Remove-Item "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Force -ErrorAction 'SilentlyContinue'
    Rename-Item -path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension).tmp" `
      -newname "$($ImageOS)-$($stamp).$($ImageFileExtension)"
    Write-Host -ForegroundColor Green " Done."

    # check file hash
    Write-Host "Checking file hash for downloaded image..." -NoNewline
    Write-Verbose $(Get-Date)
    $hashSums = [System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest $ImageHashPath -UseBasicParsing).Content)
    Switch -Wildcard ($ImageHashPath) {
      '*SHA256*' {
        $fileHash = Get-FileHash "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Algorithm SHA256
      }
      '*SHA512*' {
        $fileHash = Get-FileHash "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -Algorithm SHA512
      }
      default {throw "$ImageHashPath not supported."}
    }
    if (($hashSums | Select-String -pattern $fileHash.Hash -SimpleMatch).Count -eq 0) {throw "File hash check failed"}
    Write-Verbose $(Get-Date)
    Write-Host -ForegroundColor Green " Done."

  }
  catch {
    cleanupFile "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)"
    $ErrorMessage = $_.Exception.Message
    Write-Host "Error: $ErrorMessage"
    exit 1
  }
}

# check if image is extracted already
if (!(test-path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd")) {
  try {
    Write-Host 'Expanding archive...' -NoNewline
    if ($ImageFileExtension.Contains(".zip")) {
      Expand-Archive -Path "$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)" -DestinationPath "$ImageCachePath" -Force
    } elseif (($ImageFileExtension.Contains(".tar.gz")) -or ($ImageFileExtension.Contains("tar.xz"))) {
      # using bsdtar - src: https://github.com/libarchive/libarchive/
      # src: https://unix.stackexchange.com/a/23746/353700
      #& $bsdtarPath "-x -C `"$($ImageCachePath)`" -f `"$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)`""
      Start-Process `
        -FilePath $bsdtarPath `
        -ArgumentList  "-x","-C `"$($ImageCachePath)`"","-f `"$($ImageCachePath)\$($ImageOS)-$($stamp).$($ImageFileExtension)`"" `
        -Wait -NoNewWindow `
        -RedirectStandardOutput "$($tempPath)\bsdtar.log"
    } else {
      Write-Warning "Unsupported image in archive"
      exit 1
    }

    # rename bionic-server-cloudimg-amd64.vhd (or however they pack it) to $ImageFileName.vhd
    $fileExpanded = Get-ChildItem "$($ImageCachePath)\*.vhd","$($ImageCachePath)\*.vhdx","$($ImageCachePath)\*.raw" -File | Sort-Object LastWriteTime | Select-Object -last 1
    Write-Verbose "Expanded file name: $fileExpanded"
    if ($fileExpanded -like "*.vhd") {
      Rename-Item -path $fileExpanded -newname "$ImageFileName.vhd"
    } elseif ($fileExpanded -like "*.raw") {
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$fileExpanded"
      Write-Verbose "qemu-img convert to vhd"
      Write-Verbose "$qemuImgPath convert -f raw $fileExpanded -O vpc $($ImageCachePath)\$ImageFileName.vhd"
      & $qemuImgPath convert -f raw "$fileExpanded" -O vpc "$($ImageCachePath)\$($ImageFileName).vhd"
      # remove source image after conversion
      Remove-Item "$fileExpanded" -force
    } else {
      Write-Warning "Unsupported disk image extracted."
      exit 1
    }
    Write-Host -ForegroundColor Green " Done."

    Write-Host 'Convert VHD fixed to VDH dynamic...' -NoNewline
    try {
      Convert-VHD -Path "$($ImageCachePath)\$ImageFileName.vhd" -DestinationPath "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -VHDType Dynamic -DeleteSource
      Write-Host -ForegroundColor Green " Done."
    } catch {
      Write-Warning $_
      Write-Warning "Failed to convert the disk using 'Convert-VHD', falling back to qemu-img... "
      Write-Host "qemu-img info for source untouched cloud image: "
      & $qemuImgPath info "$($ImageCachePath)\$ImageFileName.vhd"
      Write-Verbose "qemu-img convert to vhd"
      & $qemuImgPath convert "$($ImageCachePath)\$ImageFileName.vhd" -O vpc -o subformat=dynamic "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd"
      # remove source image after conversion
      Remove-Item "$($ImageCachePath)\$ImageFileName.vhd" -force

      #Write-Warning "Failed to convert the disk, will use it as is..."
      #Rename-Item -path "$($ImageCachePath)\$ImageFileName.vhd" -newname "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" # not VHDX
      Write-Host -ForegroundColor Green " Done."
    }
  }
  catch {
    cleanupFile "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd"
    $ErrorMessage = $_.Exception.Message
    Write-Host "Error: $ErrorMessage"
    exit 1
  }
}

# File path for to-be provisioned VHD
$VMDiskPath = "$($VMStoragePath)\$($VMName).vhd"
if ($VMGeneration -eq 2) {
  $VMDiskPath = "$($VMStoragePath)\$($VMName).vhdx"
}
cleanupFile $VMDiskPath

# Prepare VHD... (could also use copy)
Write-Host "Prepare virtual disk..." -NoNewline
try {
  Convert-VHD -Path "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -DestinationPath $VMDiskPath -VHDType Dynamic
  Write-Host -ForegroundColor Green " Done."
  if ($VHDSizeBytes -and ($VHDSizeBytes -gt 30GB)) {
    Write-Host "Resize VHD to $([int]($VHDSizeBytes / 1024 / 1024 / 1024)) GB..." -NoNewline
    Resize-VHD -Path $VMDiskPath -SizeBytes $VHDSizeBytes
    Write-Host -ForegroundColor Green " Done."
  }
} catch {
  Write-Warning "Failed to convert and resize, will just copy it ..."
  Copy-Item "$($ImageCachePath)\$($ImageOS)-$($stamp).vhd" -Destination $VMDiskPath
}

# Create new virtual machine and start it
Write-Host "Create VM..." -NoNewline
$vm = new-vm -Name $VMName -MemoryStartupBytes $VMMemoryStartupBytes `
               -Path "$VMMachinePath" `
               -VHDPath "$VMDiskPath" -Generation $VMGeneration `
               -BootDevice VHD -Version $VMVersion | out-null
Set-VMProcessor -VMName $VMName -Count $VMProcessorCount
If ($DynamicMemoryEnabled) {
  Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $DynamicMemoryEnabled -MaximumBytes $MaximumBytes -MinimumBytes $MinimumBytes
} else {
  Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $DynamicMemoryEnabled
}
# make sure VM has DVD drive needed for provisioning
if ($null -eq (Get-VMDvdDrive -VMName $VMName)) {
  Add-VMDvdDrive -VMName $VMName
}
Set-VMDvdDrive -VMName $VMName -Path "$metaDataIso"

If (($null -ne $virtualSwitchName) -and ($virtualSwitchName -ne "")) {
  Write-Verbose "Connecting VMnet adapter to virtual switch '$virtualSwitchName'..."
} else {
  Write-Warning "No Virtual network switch given."
  $SwitchList = Get-VMSwitch | Select-Object Name
  If ($SwitchList.Count -eq 1 ) {
    Write-Warning "Using single Virtual switch found: '$($SwitchList.Name)'"
    $virtualSwitchName = $SwitchList.Name
  } elseif (Get-VMSwitch | Select-Object Name | Select-String "Default Switch") {
    Write-Warning "Multiple Switches found; using found 'Default Switch'"
    $virtualSwitchName = "Default Switch"
  }
}
If (($null -ne $virtualSwitchName) -and ($virtualSwitchName -ne "")) {
  Get-VMNetworkAdapter -VMName $VMName | Connect-VMNetworkAdapter -SwitchName "$virtualSwitchName"
} else {
  Write-Warning "No Virtual network switch given and could not automatically selected."
  Write-Warning "Please use parameter -virtualSwitchName 'Switch Name'."
  exit 1
}

$VMNetworkAdapter = Get-VMNetworkAdapter -VMName $VMName
$VMNetworkAdapterName = $VMNetworkAdapter.Name
If ((($null -ne $VMVlanID) -and ([int]($VMVlanID) -ne 0)) -or
   ((($null -ne $VMNativeVlanID) -and ([int]($VMNativeVlanID) -ne 0)) -and
    (($null -ne $VMAllowedVlanIDList) -and ($VMAllowedVlanIDList -ne "")))) {
  If (($null -ne $VMNativeVlanID) -and ([int]($VMNativeVlanID) -ne 0) -and
      ($null -ne $VMAllowedVlanIDList) -and ($VMAllowedVlanIDList -ne "")) {
    Write-Host "Setting native Vlan ID $VMNativeVlanID with trunk Vlan IDs '$VMAllowedVlanIDList'"
    Write-Host "on virtual network adapter '$VMNetworkAdapterName'..."
    Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName "$VMNetworkAdapterName" `
                -Trunk  -NativeVlanID $VMNativeVlanID -AllowedVlanIDList $VMAllowedVlanIDList
  } else {
    Write-Host "Setting Vlan ID $VMVlanID on virtual network adapter '$VMNetworkAdapterName'..."
    Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName "$VMNetworkAdapterName" `
                -Access -VlanId $VMVlanID
  }
} else {
  Write-Verbose "Let virtual network adapter '$VMNetworkAdapterName' untagged."
}

If (($null -ne $StaticMacAddress) -and ($StaticMacAddress -ne "")) {
  Write-Verbose "Setting static MAC address '$StaticMacAddress' on VMnet adapter..."
  Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $StaticMacAddress
} else {
  Write-Verbose "Using default dynamic MAC address asignment."
}

# hyper-v gen2 specific features
if ($VMGeneration -eq 2) {
  Write-Verbose "Setting secureboot for Hyper-V Gen2..."
  # configure secure boot, src: https://www.altaro.com/hyper-v/hyper-v-2016-support-linux-secure-boot/
  Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')

  # Ubuntu 18.04+ supports enhanced session and so Debian 10/11
  Set-VM -VMName $VMName -EnhancedSessionTransportType HvSocket

  # For copy&paste service (hv_fcopy_daemon) between host and guest we need also this
  # guest service interface activation which has sadly language dependent setup:
  # PS> Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"
  # PS> Enable-VMIntegrationService -VMName $VMName -Name "Gastdienstschnittstelle"
  # https://administrator.de/forum/hyper-v-cmdlet-powershell-sprachproblem-318175.html
  Get-VMIntegrationService -VMName $VMName `
            | Where-Object {$_.Name -match 'Gastdienstschnittstelle|Guest Service Interface'} `
            | Enable-VMIntegrationService
}

# disable automatic checkpoints, https://github.com/hashicorp/vagrant/issues/10251#issuecomment-425734374
if ($null -ne (Get-Command Hyper-V\Set-VM).Parameters["AutomaticCheckpointsEnabled"]){
  Hyper-V\Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false
}

Write-Host -ForegroundColor Green " Done."

# set chassistag to "Azure chassis tag" as documented in https://git.launchpad.net/cloud-init/tree/cloudinit/sources/DataSourceAzure.py#n51
Write-Host "Set Azure chasis tag ..." -NoNewline
& .\Set-VMAdvancedSettings.ps1 -VM $VMName -ChassisAssetTag '7783-7084-3265-9085-8269-3286-77' -Force -Verbose:$verbose
Write-Host -ForegroundColor Green " Done."
Write-Host "Set BIOS and chasis serial number to machine ID $VmMachineId ..." -NoNewline
& .\Set-VMAdvancedSettings.ps1 -VM $VMName -BIOSSerialNumber $VmMachineId -ChassisSerialNumber $vmMachineId -Force -Verbose:$verbose
Write-Host -ForegroundColor Green " Done."

# redirect com port to pipe for VM serial output, src: https://superuser.com/a/1276263/145585
Set-VMComPort -VMName $VMName -Path \\.\pipe\$VMName-com1 -Number 1
Write-Verbose "Serial connection: \\.\pipe\$VMName-com1"

# enable guest integration services (could be used for Copy-VMFile)
Get-VMIntegrationService -VMName $VMName | Where-Object Name -match 'guest' | Enable-VMIntegrationService

# Clean up temp directory
Remove-Item -Path $tempPath -Recurse -Force

# Make checkpoint when debugging https://stackoverflow.com/a/16297557/1155121
if ($PSBoundParameters.Debug -eq $true) {
  # make VM snapshot before 1st run
  Write-Host "Creating checkpoint..." -NoNewline
  Checkpoint-VM -Name $VMName -SnapshotName Initial
  Write-Host -ForegroundColor Green " Done."
}

Write-Host "Starting VM..." -NoNewline
Start-VM $VMName
Write-Host -ForegroundColor Green " Done."

# TODO check if VM has got an IP ADDR, if address is missing then write error because provisioning won't work without IP, src: https://stackoverflow.com/a/27999072/1155121


if ($ShowSerialConsoleWindow) {
  # start putty with serial connection to newly created VM
  # TODO alternative: https://stackoverflow.com/a/48661245/1155121
  $env:PATH = "D:\share\programi\putty;" + $env:PATH
  try {
    Get-Command "putty" | out-null
    start-sleep -seconds 2
    & "PuTTY" -serial "\\.\pipe\$VMName-com1" -sercfg "115200,8,n,1,N"
  }
  catch {
    Write-Verbose "putty not available"
  }
}

if ($ShowVmConnectWindow) {
  # Open up VMConnect
  Start-Process "vmconnect" "localhost","$VMName" -WindowStyle Normal
}

Write-Host "Done"