param(
  [int]$AdoPort = 8080,
  [string]$SqlInstance = "SQLEXPRESS",
  [string]$CollectionName = "DefaultCollection"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-ado.log" -Append

function Log { param([string]$m) Write-Host $m }

function Ensure-Tls12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
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
  Refresh-Path
}

function Install-IisPrereqs {
  Log "[INFO] Installing IIS prerequisites..."
  Import-Module ServerManager

  $features = @(
    "Web-Server",
    "Web-WebServer",
    "Web-Common-Http",
    "Web-Default-Doc",
    "Web-Static-Content",
    "Web-Http-Errors",
    "Web-Http-Logging",
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
    "NET-Framework-45-Core",
    "NET-Framework-45-ASPNET"
  )

  $result = Install-WindowsFeature -Name $features -IncludeManagementTools
  if (-not $result.Success) { throw "Failed to install IIS prerequisites." }
  Log "[INFO] IIS prerequisites installed."
}

function Ensure-SqlExpress {
  param([string]$Instance)

  Log "[INFO] Installing SQL Server Express..."
  # Guarantee local Administrators are SQL sysadmin so students (local admins) can configure ADO.
  $params = "/SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
  choco install sql-server-express -y --no-progress --params "`'$params`'"

  Log "[INFO] Ensuring SQL Express service is running..."
  $svcName = "MSSQL`$$Instance"
  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
  if ($null -eq $svc) { throw "SQL service $svcName not found after install." }
  if ($svc.Status -ne "Running") { Start-Service $svc.Name }

  Log "[INFO] SQL Express is running."
}

function Install-AdoExpress {
  $adoExe = "C:\Tools\azuredevopsexpress2022.2.exe"
  $adoUrl = "https://go.microsoft.com/fwlink/?LinkId=2269947"

  if (-not (Test-Path $adoExe)) {
    Log "[INFO] Downloading Azure DevOps Server Express installer..."
    Ensure-Tls12
    Invoke-WebRequest -Uri $adoUrl -OutFile $adoExe -UseBasicParsing
  } else {
    Log "[INFO] ADO installer already present."
  }

  Log "[INFO] Installing Azure DevOps Server Express..."
  $p = Start-Process -FilePath $adoExe -ArgumentList "/quiet","/norestart" -Wait -PassThru

  if ($p.ExitCode -eq 0) {
    Log "[INFO] ADO installer completed (0)."
  }
  elseif ($p.ExitCode -eq 3010) {
    Log "[INFO] ADO installer completed (3010 = reboot required). Not rebooting automatically."
    Log "[INFO] If the Admin Console requests it later, reboot once."
  }
  else {
    throw "ADO installer failed with exit code $($p.ExitCode)"
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

function Prepare-AdoUnattendFile {
  param(
    [int]$Port,
    [string]$SqlInstanceName,
    [string]$Collection
  )

  $tfsConfig = Find-TfsConfig
  if (-not $tfsConfig) { throw "TfsConfig.exe not found (ADO likely not installed)." }

  $iniPath = "C:\Tools\ado-basic.ini"

  Log "[INFO] Creating ADO unattend file..."
  $createArgs = @("unattend","/create","/type:basic","/unattendfile:$iniPath")
  & $tfsConfig @createArgs | Out-Null

  if (-not (Test-Path $iniPath)) { throw "Unattend file was not created at $iniPath" }

  $machine = $env:COMPUTERNAME

  $sqlLine          = "SqlInstance=localhost\$SqlInstanceName"
  $siteBindingsLine  = "SiteBindings=http:*:$($Port):"
  $publicUrlLine     = "PublicUrl=http://$machine`:$($Port)/"
  $collectionLine    = "CollectionName=$Collection"
  $urlHostLine       = "UrlHostNameAlias=$machine"

  Log "[INFO] Updating unattend file values..."
  (Get-Content $iniPath) `
    -replace '^SqlInstance=.*$', $sqlLine `
    -replace '^SiteBindings=.*$', $siteBindingsLine `
    -replace '^PublicUrl=.*$', $publicUrlLine `
    -replace '^CollectionName=.*$', $collectionLine `
    -replace '^UrlHostNameAlias=.*$', $urlHostLine |
    Set-Content -Path $iniPath -Encoding UTF8

  Log "[INFO] Unattend file prepared at: $iniPath"
  Log "[INFO] Next step (manual, reliable): Open 'Azure DevOps Server Administration Console' -> Configure Installed Features -> Basic"
  Log "[INFO] Use SQL instance: localhost\$SqlInstanceName and port $Port if prompted."
}

try {
  Assert-Admin
  Ensure-Tls12

  Log "[INFO] === Installing prerequisites, SQL, and ADO Express (no auto-config) ==="
  Install-IisPrereqs
  Ensure-Choco
  Ensure-SqlExpress -Instance $SqlInstance
  Install-AdoExpress
  Prepare-AdoUnattendFile -Port $AdoPort -SqlInstanceName $SqlInstance -Collection $CollectionName

  Log "[INFO] DONE."
}
finally {
  try { Stop-Transcript } catch {}
}
