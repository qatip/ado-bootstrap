param(
  [int]$AdoPort = 8080,
  [string]$SqlInstance = "SQLEXPRESS",
  [string]$CollectionName = "DefaultCollection"
)

$ErrorActionPreference = "Stop"
$global:RebootRequired = $false

# ---------------------------
# Logging
# ---------------------------
New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-ado.log" -Append

function Log { param([string]$m) Write-Host $m }

function Ensure-Tls12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
  }
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
}

function Ensure-Choco {
  Ensure-Tls12
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "[INFO] Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force | Out-Null
    Ensure-Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  } else {
    Log "[INFO] Chocolatey already installed."
  }
  Refresh-Path
}

function Install-IisPrereqs {
  Log "[INFO] Installing IIS prerequisites for Azure DevOps Server..."
  Import-Module ServerManager

  $features = @(
    "Web-Server",
    "Web-WebServer",
    "Web-Common-Http",
    "Web-Default-Doc",
    "Web-Static-Content",
    "Web-Http-Errors",
    "Web-Http-Redirect",
    "Web-Http-Logging",
    "Web-Log-Libraries",
    "Web-Request-Monitor",
    "Web-Filtering",
    "Web-Stat-Compression",
    "Web-Dyn-Compression",

    "Web-Security",
    "Web-Windows-Auth",

    "Web-App-Dev",
    "Web-Net-Ext45",
    "Web-Asp-Net45",
    "Web-ISAPI-Ext",
    "Web-ISAPI-Filter",

    "Web-Mgmt-Tools",
    "Web-Mgmt-Console",
    "Web-Mgmt-Service",

    "NET-Framework-45-Core",
    "NET-Framework-45-ASPNET"
  )

  $missing = @()
  foreach ($f in $features) {
    $feat = Get-WindowsFeature $f
    if ($null -eq $feat -or $feat.InstallState -ne "Installed") { $missing += $f }
  }

  if ($missing.Count -gt 0) {
    Log "[INFO] Installing missing IIS/.NET features..."
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    if (-not $result.Success) { throw "Failed to install required IIS features." }
    Log "[INFO] IIS/.NET prerequisites installed."
  } else {
    Log "[INFO] IIS/.NET prerequisites already installed."
  }
}

function Ensure-SqlExpress {
  param([string]$Instance)

  Log "[INFO] Installing SQL Server Express (Chocolatey package)..."
  # Critical: grant local Administrators SQL sysadmin so 'azureuser' can configure ADO
  # Chocolatey passes these to the installer.
  $params = "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
  choco install sql-server-express -y --no-progress --params "`'$params`'"

  Log "[INFO] Checking SQL Express service..."
  $svcName = "MSSQL`$$Instance"
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if ($null -eq $svc) { throw "SQL service $svcName not found after install." }
  if ($svc.Status -ne "Running") { Start-Service $svc.Name }
  Log "[INFO] SQL Express service is running."
}

function Install-AdoExpress {
  $adoExe = "C:\Tools\azuredevopsexpress2022.2.exe"
  $adoUrl = "https://go.microsoft.com/fwlink/?LinkId=2269947"  # Express 2022.2

  if (-not (Test-Path $adoExe)) {
    Log "[INFO] Downloading ADO Server Express installer..."
    Ensure-Tls12
    Invoke-WebRequest -Uri $adoUrl -OutFile $adoExe -UseBasicParsing
  } else {
    Log "[INFO] ADO installer already present."
  }

  Log "[INFO] Installing ADO Server Express (silent)..."
  $p = Start-Process -FilePath $adoExe -ArgumentList "/quiet","/norestart" -Wait -PassThru

  switch ($p.ExitCode) {
    0 {
      Log "[INFO] ADO installer completed (exit code 0)."
    }
    3010 {
      Log "[INFO] ADO installer completed (exit code 3010 = reboot required). Continuing without reboot..."
      $global:RebootRequired = $true
    }
    default {
      throw "ADO installer failed with exit code $($p.ExitCode)"
    }
  }
}

function Find-TfsConfig {
  $tfsConfig = Get-ChildItem -Path "C:\Program Files\Azure DevOps Server*\Tools\TfsConfig.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

  if (-not $tfsConfig) {
    $tfsConfig = Get-ChildItem -Path "C:\Program Files\Microsoft Team Foundation Server*\Tools\TfsConfig.exe" -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
  }
  return $tfsConfig
}

function Configure-AdoBasic {
  param(
    [string]$Instance,
    [string]$Collection
  )

  $tfsConfig = Find-TfsConfig
  if (-not $tfsConfig) { throw "Could not find TfsConfig.exe after installation." }

  $iniPath = "C:\Tools\ado-basic.ini"

  if (-not (Test-Path $iniPath)) {
    Log "[INFO] Creating unattend file..."
    & $tfsConfig unattend /create /type:basic /unattendfile:$iniPath | Out-Null
  } else {
    Log "[INFO] Unattend file already exists: $iniPath"
  }

  # Keep inputs minimal and known-good
  $inputs = "SqlInstance=.\$Instance;CollectionName=$Collection"

  Log "[INFO] Running BASIC configuration (minimal inputs)..."
  & $tfsConfig unattend /configure /type:basic /inputs:$inputs | Out-Host

  if ($LASTEXITCODE -ne 0) {
    throw "TfsConfig returned exit code $LASTEXITCODE"
  }

  Log "[INFO] BASIC configuration completed."
}

function Wait-ForPort {
  param([int]$Port, [int]$TimeoutSec = 300)

  Log "[INFO] Waiting for TCP port $Port to listen..."
  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    $listening = $false
    try {
      $out = netstat -ano | Select-String ":$Port\s+LISTENING"
      if ($out) { $listening = $true }
    } catch {}

    if ($listening) {
      Log "[INFO] Port $Port is LISTENING."
      return
    }

    Start-Sleep -Seconds 5
  }

  throw "Port $Port did not become LISTENING within $TimeoutSec seconds."
}

function Wait-ForHttp {
  param([int]$Port, [int]$TimeoutSec = 300)

  $url = "http://localhost:$Port/tfs"
  Log "[INFO] Waiting for HTTP response from $url ..."
  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    try {
      Ensure-Tls12
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
      Log "[INFO] HTTP responded: $($r.StatusCode)"
      return
    } catch {
      Start-Sleep -Seconds 5
    }
  }

  throw "No HTTP response from $url within $TimeoutSec seconds."
}

# ---------------------------
# Main
# ---------------------------
try {
  Assert-Admin
  Ensure-Tls12

  Log "[INFO] Starting ADO Express install + config..."
  Install-IisPrereqs
  Ensure-Choco
  Ensure-SqlExpress -Instance $SqlInstance
  Install-AdoExpress
  Configure-AdoBasic -Instance $SqlInstance -Collection $CollectionName

  # Verify listener
  Wait-ForPort -Port $AdoPort -TimeoutSec 600
  Wait-ForHttp -Port $AdoPort -TimeoutSec 600

  Log "[INFO] SUCCESS. Browse (inside VM): http://localhost:$AdoPort/tfs"
  Log "[INFO] If NSG allows, browse externally: http://<VM_PUBLIC_IP>:$AdoPort/tfs"

  # Only reboot after successful config/verification
  if ($global:RebootRequired) {
    Log "[INFO] Reboot was requested by installer (3010). Rebooting now AFTER successful configuration..."
    Stop-Transcript
    Restart-Computer -Force
    exit 0
  }
}
finally {
  try { Stop-Transcript } catch {}
}

