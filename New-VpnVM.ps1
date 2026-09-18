#Requires -RunAsAdministrator
<#
  Creates the Hyper-V VM that will host the VPN server.
  Run in an elevated PowerShell on the Windows host.

    .\New-VpnVM.ps1
    .\New-VpnVM.ps1 -IsoPath D:\iso\ubuntu-server.iso -IsoSha256 <trusted-sha256>

  It only builds the VM and boots the installer. You still click through the
  Ubuntu install once — tick "Install OpenSSH server" when it offers.
#>
[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
  [string] $VMName     = 'vpn',
  [string] $IsoPath    = '',
  [string] $IsoSha256 = '',
  [ValidateRange(1, 1024)]
  [int]    $MemoryGB   = 2,
  [ValidateRange(1, 256)]
  [int]    $CpuCount   = 2,
  [ValidateRange(10, 65536)]
  [int]    $DiskGB     = 20,
  [string] $SwitchName = 'VPN-External',
  [string] $VMPath     = 'C:\HyperV'
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[!] $m"  -ForegroundColor Yellow }

# ---------------------------------------------------------------- checks
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
  throw "The Hyper-V PowerShell module is not available. Enable Hyper-V first."
}
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
  throw "A VM named '$VMName' already exists. Remove it or pass -VMName."
}
New-Item -ItemType Directory -Force -Path $VMPath | Out-Null

# ---------------------------------------------------------------- iso
# Verify before creating a switch or VM. Custom images require an independently
# obtained SHA256; never delete a user-supplied image on verification failure.
if (-not $IsoPath) {
  $iso = 'ubuntu-26.04.1-live-server-amd64.iso'
  $IsoPath = Join-Path $VMPath $iso
  $IsoSha256 = 'cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927'
  if (-not (Test-Path -LiteralPath $IsoPath)) {
    Info "downloading $iso (about 3 GB)"
    $ProgressPreference = 'SilentlyContinue'
    $partial = "$IsoPath.partial"
    Invoke-WebRequest -Uri "https://releases.ubuntu.com/26.04/$iso" -OutFile $partial
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $IsoSha256) {
      throw "Downloaded ISO checksum mismatch. Inspect $partial before retrying."
    }
    Move-Item -LiteralPath $partial -Destination $IsoPath
  }
}
if ($IsoSha256 -notmatch '^[a-fA-F0-9]{64}$') {
  throw "Supply -IsoSha256 with the trusted SHA256 of your custom ISO."
}
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "ISO not found: $IsoPath" }
Info "verifying ISO checksum"
if ((Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash -ne $IsoSha256) {
  throw "ISO checksum mismatch. The file has been preserved for inspection."
}
Info "checksum ok"

# ---------------------------------------------------------------- switch
$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $sw) {
  # The VM needs its own address on the LAN so the router can port-forward to
  # it, which means an *External* switch — Default/Internal switches sit behind
  # another layer of NAT and require additional forwarding configuration.
  $nic = Get-NetAdapter -Physical |
         Where-Object { $_.Status -eq 'Up' } |
         Sort-Object -Property Speed -Descending |
         Select-Object -First 1
  if (-not $nic) { throw "No active physical network adapter found." }

  Warn "Creating an External switch on '$($nic.Name)' briefly drops this host's"
  Warn "network connection. If you are connected over RDP you will be kicked"
  Warn "and will need to reconnect. Run this at the console if you can."
  $ans = Read-Host "Continue? (y/N)"
  if ($ans -notmatch '^[Yy]') { throw "Aborted by user." }

  Info "creating external switch '$SwitchName' on '$($nic.Name)'"
  New-VMSwitch -Name $SwitchName -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
} else {
  Info "reusing existing switch '$SwitchName'"
  if ($sw.SwitchType -ne 'External') {
    throw "'$SwitchName' must be an External switch. Pass a different -SwitchName."
  }
}

# ---------------------------------------------------------------- vm
$vhd = Join-Path $VMPath "$VMName.vhdx"
Info "creating VM '$VMName'  ($CpuCount vCPU, ${MemoryGB}GB RAM, ${DiskGB}GB disk)"
New-VM -Name $VMName -Generation 2 `
       -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB) `
       -SwitchName $SwitchName -Path $VMPath | Out-Null

Set-VMProcessor -VMName $VMName -Count $CpuCount
# a VPN endpoint should hold a steady footprint rather than balloon
Set-VMMemory  -VMName $VMName -DynamicMemoryEnabled $false

# Generation 2 VMs default to the Microsoft Windows secure-boot template, under
# which Ubuntu will not boot at all ("no bootable device"). This is the single
# most common Hyper-V + Linux failure.
Set-VMFirmware -VMName $VMName -SecureBootTemplate MicrosoftUEFICertificateAuthority

# Pin a MAC now so a DHCP reservation can be made before the VM ever boots.
# 00-15-5D is Microsoft's Hyper-V range.
$octets = (1..3 | ForEach-Object { '{0:X2}' -f (Get-Random -Max 256) }) -join ''
$mac    = '00155D' + $octets
Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $mac

Add-VMDvdDrive -VMName $VMName -Path $IsoPath
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

# an always-on VPN must come back by itself after a host reboot or power cut
Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30 `
                     -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false

Start-VM -Name $VMName
$pretty = ($mac -replace '(.{2})(?!$)', '$1-')

Write-Host ""
Info "VM '$VMName' created and booting the Ubuntu installer."
Write-Host @"

  MAC address : $pretty

  Next, on the Windows host:
    1. Open Hyper-V Manager and connect to '$VMName' to run the installer.
       Tick "Install OpenSSH server" when the installer offers it.
    2. On your router, give MAC $pretty a DHCP reservation so the
       VM's LAN address never changes.
    3. Forward TCP port 443 to that reserved address.

"@
