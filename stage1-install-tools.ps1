$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Git for Windows ---
$gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.1/Git-2.53.0-64-bit.exe"
$gitExe = "C:\Tools\Git-Installer.exe"
Start-BitsTransfer -Source $gitUrl -Destination $gitExe
Start-Process -FilePath $gitExe -ArgumentList "/VERYSILENT","/NORESTART" -Wait

# --- Azure CLI ---
$azUrl  = "https://aka.ms/installazurecliwindows"
$azMsi  = "C:\Tools\AzureCLI.msi"
Invoke-WebRequest -Uri $azUrl -OutFile $azMsi -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i",$azMsi,"/quiet","/norestart" -Wait

# --- Terraform (pin version) ---
$tfVersion = "1.10.5"
$tfZip = "C:\Tools\terraform.zip"
$tfDir = "C:\Tools\terraform"
Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform/$tfVersion/terraform_${tfVersion}_windows_amd64.zip" -OutFile $tfZip -UseBasicParsing
New-Item -ItemType Directory -Force -Path $tfDir | Out-Null
Expand-Archive -Path $tfZip -DestinationPath $tfDir -Force

# --- Add to PATH (Machine) ---
$pathsToAdd = @(
  "C:\Program Files\Git\cmd",
  "C:\Tools\terraform",
  "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
)
$machinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
foreach ($p in $pathsToAdd) {
  if ($machinePath -notlike "*$p*") {
    $machinePath = $machinePath.TrimEnd(';') + ";" + $p
  }
}
[Environment]::SetEnvironmentVariable("Path", $machinePath, "Machine")

Write-Host "[OK] Tools installed. Rebooting now to refresh PATH..."
Restart-Computer -Force