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

  # Refresh PATH for this process (CSE sessions can have stale PATH)
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
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
  choco install sql-server-express -y --no-progress

  Log "[INFO] Checking SQL Express service..."
  $svcName = "MSSQL`$$Instance"
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if ($null -eq $svc) { throw "SQL service $svcName not found after install." }
  if ($svc.Status -ne "Running") { Start-Service $svc.Name }
  Log "[INFO] SQL Express service is running."
}

function Install-AdoExpress {
  $adoExe = "C:\Tools\azuredevopsexpress2022.2.exe"
  $adoUrl = "https://go.microsoft.com/fwlink/?LinkId=2269947"

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
      Log "[INFO] ADO installer completed (exit code 3010 = reboot required)."
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
    [int]$Port,
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

  $publicUrl = "http://localhost:$Port/tfs"
  $inputs = "SqlInstance=.\$Instance;CollectionName=$Collection;PublicUrl=$publicUrl;WebSiteVDirName=tfs;WebSitePort=$Port"

  Log "[INFO] Running BASIC configuration..."
  & $tfsConfig unattend /configure /type:basic /inputs:$inputs | Out-Host

  if ($LASTEXITCODE -ne 0) {
    throw "TfsConfig returned exit code $LASTEXITCODE"
  }

  Log "[INFO] BASIC configuration completed."
}

function Wait-ForAdo {
  param([int]$Port)

  $url = "http://localhost:$Port/tfs"
  Log "[INFO] Waiting for ADO to respond at $url ..."

  $deadline = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $deadline) {
    try {
      Ensure-Tls12
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
        Log "[INFO] ADO responded with HTTP $($r.StatusCode)."
        return
      }
    } catch {
      Start-Sleep -Seconds 5
    }
  }

  throw "ADO did not respond at $url within 5 minutes."
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

  if ($global:RebootRequired) {
    Log "[INFO] Reboot required after ADO install. Restarting now..."
    Stop-Transcript
    Restart-Computer -Force
    exit 0
  }

  Configure-AdoBasic -Port $AdoPort -Instance $SqlInstance -Collection $CollectionName
  Wait-ForAdo -Port $AdoPort

  Log "[INFO] Done. Browse (inside VM): http://localhost:$AdoPort/tfs"
}
finally {
  try { Stop-Transcript } catch {}
}
