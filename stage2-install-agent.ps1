param(
  [Parameter(Mandatory=$true)][string]$AdoUrl,   # e.g. http://vm-devops:8080/  (or http://<public-ip>:8080/)
  [Parameter(Mandatory=$true)][string]$Pat,
  [string]$Pool = "Default",
  [string]$AgentName = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "C:\Tools" | Out-Null

$agentVersion = "4.268.0"
$agentZip = "C:\Tools\vsts-agent-win-x64-$agentVersion.zip"
$agentUrl = "https://download.agent.dev.azure.com/agent/$agentVersion/vsts-agent-win-x64-$agentVersion.zip"
$agentDir = "C:\ado-agent"

Write-Host "[INFO] Downloading agent $agentVersion..."
Invoke-WebRequest -Uri $agentUrl -OutFile $agentZip -UseBasicParsing

Write-Host "[INFO] Extracting to $agentDir..."
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
Expand-Archive -Path $agentZip -DestinationPath $agentDir -Force

Set-Location $agentDir

Write-Host "[INFO] Configuring agent (unattended) ..."
cmd.exe /c "config.cmd --unattended --url `"$AdoUrl`" --auth pat --token `"$Pat`" --pool `"$Pool`" --agent `"$AgentName`" --work _work --runAsService --acceptTeeEula"

Write-Host "[OK] Agent installed as a Windows service."
Write-Host "     Check Services: Azure Pipelines Agent ($AgentName)"