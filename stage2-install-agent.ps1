param(
  [string]$AdoUrl,                 # e.g. http://vm-devops:8080/
  [string]$Pat,                    # PAT string
  [string]$Pool = "Default",       # Agent pool name
  [string]$AgentName = $env:COMPUTERNAME,
  [string]$AgentVersion = "4.268.0"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null
Start-Transcript -Path "C:\Tools\install-agent.log" -Append

function Log { param([string]$m) Write-Host "[INFO] $m" }
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
  }
}

try {
  Assert-Admin

  if ([string]::IsNullOrWhiteSpace($AdoUrl)) { throw "AdoUrl is required (e.g. http://vm-devops:8080/)." }
  if ([string]::IsNullOrWhiteSpace($Pat))    { throw "Pat is required." }

  $agentZip = "C:\Tools\vsts-agent-win-x64-$AgentVersion.zip"
  $agentUri = "https://download.agent.dev.azure.com/agent/$AgentVersion/vsts-agent-win-x64-$AgentVersion.zip"
  $agentDir = "C:\ado-agent"

  Log "Downloading Azure Pipelines agent $AgentVersion..."
  Invoke-WebRequest -Uri $agentUri -OutFile $agentZip -UseBasicParsing

  Log "Extracting agent..."
  New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
  Expand-Archive -Path $agentZip -DestinationPath $agentDir -Force

  Set-Location $agentDir

  # Clean any previous config (safe if not configured)
  if (Test-Path ".\config.cmd") {
    Log "Configuring agent (unattended)..."
  } else {
    throw "config.cmd not found in $agentDir"
  }

  # Unattended config
  # --runAsService installs/sets service
  # --windowsLogonAccount/Password omitted -> runs as default service account
  .\config.cmd --unattended `
    --url "$AdoUrl" `
    --auth pat `
    --token "$Pat" `
    --pool "$Pool" `
    --agent "$AgentName" `
    --acceptTeeEula `
    --runAsService `
    --work "_work" `
    --replace

  Log "Starting agent service..."
  .\run.cmd --startuptype service | Out-Null

  Log "Done. Verify service is running:"
  Log "  Get-Service | ? Name -like 'vstsagent*'"
}
finally {
  try { Stop-Transcript } catch {}
}
