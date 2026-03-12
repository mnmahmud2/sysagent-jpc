$base = "C:\ProgramData\SysAgent"
$queue = "$base\Queue"
$log = "$base\log"

New-Item -ItemType Directory -Force -Path $queue | Out-Null
New-Item -ItemType Directory -Force -Path $log | Out-Null


# ================================
# NEXTCLOUD CREDENTIAL (SILENT) SECRET
# ================================

$credPath = "$base\cred.json"

$credData = Get-Content $credPath | ConvertFrom-Json

$user = $credData.username
$pass = $credData.password

$securePass = ConvertTo-SecureString $pass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($user,$securePass)


# ================================
# DEVICE INFO
# ================================

$hostname = $env:COMPUTERNAME
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$serial = (Get-CimInstance Win32_BIOS).SerialNumber
$cpu = (Get-CimInstance Win32_Processor).Name

$totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,2)
$ramFree = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,2)
$ramUsed = [math]::Round($totalRAM - $ramFree,2)

$cpuLoad = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
$cpuLoad = [math]::Round($cpuLoad,2)


# ================================
# DISK INFORMATION
# ================================

$disks = @()

Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {

$total = [math]::Round($_.Size/1GB,2)
$free = [math]::Round($_.FreeSpace/1GB,2)
$used = [math]::Round($total-$free,2)

$disks += [PSCustomObject]@{

drive = $_.DeviceID
filesystem = $_.FileSystem
total_gb = $total
used_gb = $used
free_gb = $free

}

}


# ================================
# NETWORK INTERFACES
# ================================

$networkInterfaces = @()

$adapters = Get-NetAdapter -ErrorAction SilentlyContinue

foreach ($adapter in $adapters) {

$ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where {$_.IPAddress -notlike "169.*"}

$gateway = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select -First 1).NextHop

$dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

$dhcp = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue).Dhcp

$ssid = ""

if ($adapter.InterfaceDescription -match "Wireless|Wi-Fi|802.11") {

try {

$ssid = (netsh wlan show interfaces | Select-String "SSID" | Select -First 1).ToString().Split(":")[1].Trim()

} catch {}

}

$interfacesubnet = $null

if ($ipInfo) {

$interfacesubnet = $ipInfo.PrefixLength

}

$networkInterfaces += [PSCustomObject]@{

name = $adapter.Name
description = $adapter.InterfaceDescription
mac = $adapter.MacAddress
status = $adapter.Status
link_speed = $adapter.LinkSpeed

ip = $ipInfo.IPAddress
subnet_prefix = $interfacesubnet

gateway = $gateway
dns_servers = $dns

dhcp_enabled = $dhcp
wifi_ssid = $ssid

}

}


# ================================
# SOFTWARE LIST
# ================================

$paths = @(
"HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
"HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$software = foreach ($path in $paths) {

Get-ItemProperty $path -ErrorAction SilentlyContinue |
Where {$_.DisplayName} |
ForEach-Object {

$size = ""

if ($_.EstimatedSize) {
$size = "{0:N1} MB" -f ($_.EstimatedSize/1024)
}

$installDate = ""

if ($_.InstallDate) {
try{
$installDate = [datetime]::ParseExact($_.InstallDate,'yyyyMMdd',$null).ToString("yyyy-MM-dd")
}catch{}
}

[PSCustomObject]@{

Name = $_.DisplayName
Publisher = $_.Publisher
InstalledOn = $installDate
Size = $size
Version = $_.DisplayVersion

}

}

}


# ================================
# BUILD JSON
# ================================

$data = @{

hostname = $hostname
serial = $serial
os = $os

cpu = $cpu
cpu_load_percent = $cpuLoad

ram_total_gb = $totalRAM
ram_used_gb = $ramUsed
ram_free_gb = $ramFree

disks = $disks

network_interfaces = $networkInterfaces

software = $software

timestamp = (Get-Date)

}

$json = $data | ConvertTo-Json -Depth 6

$file = "$queue\$hostname-$(Get-Date -Format 'yyyyMMddHHmmss').json"

$json | Out-File $file -Encoding UTF8


# ================================
# CHECK INTERNET
# ================================

$internet = Test-Connection 8.8.8.8 -Count 1 -Quiet

if ($internet) {

$nextcloud = "https://cloud.jpc.co.id/remote.php/dav/files/sysmonitoring/INV-SOFTWARE-MONITORING"

Get-ChildItem $queue | ForEach-Object {

$upload = "$nextcloud/$($_.Name)"

try{

Invoke-WebRequest `
-Uri $upload `
-Method Put `
-InFile $_.FullName `
-Credential $cred `
-UseBasicParsing

Remove-Item $_.FullName

}catch{

$_ | Out-File "$log\upload_error.txt" -Append

}

}

}



