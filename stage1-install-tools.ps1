param(
  [string]$GitUrl = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.1/Git-2.53.0-64-bit.exe",
  [string]$TerraformVersion = "1.10.5"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-devops-tools.log" -Append

function Log { param([string]$m) Write-Host "[INFO] $m" }
function Ensure-Tls12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {} }

try {
  Ensure-Tls12

  # ---------------------------
  # Git
  # ---------------------------
  Log "Installing Git..."
  $gitExe = "C:\Tools\Git-Installer.exe"
  Start-BitsTransfer -Source $GitUrl -Destination $gitExe
  Start-Process -FilePath $gitExe -ArgumentList "/VERYSILENT","/NORESTART" -Wait

  # ---------------------------
  # Azure CLI
  # ---------------------------
  Log "Installing Azure CLI..."
  $azUrl  = "https://aka.ms/installazurecliwindows"
  $azMsi  = "C:\Tools\AzureCLI.msi"
  Invoke-WebRequest -Uri $azUrl -OutFile $azMsi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i",$azMsi,"/quiet","/norestart" -Wait

  # ---------------------------
  # Terraform
  # ---------------------------
  Log "Installing Terraform $TerraformVersion..."
  $tfZip = "C:\Tools\terraform.zip"
  $tfDir = "C:\Tools\terraform"
  Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform/$TerraformVersion/terraform_${TerraformVersion}_windows_amd64.zip" -OutFile $tfZip -UseBasicParsing
  New-Item -ItemType Directory -Force -Path $tfDir | Out-Null
  Expand-Archive -Path $tfZip -DestinationPath $tfDir -Force

  # ---------------------------
  # PATH (Machine)
  # ---------------------------
  Log "Updating machine PATH..."
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

  Log "Tools installed. Rebooting to finalize PATH + installers..."
}
finally {
  try { Stop-Transcript } catch {}
}

Restart-Computer -Force
