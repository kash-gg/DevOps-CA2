[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$runtime = Join-Path $repo '.runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
Start-Transcript -Path (Join-Path $runtime 'prepare-images.log') -Force
function Run-Checked {
    param([string]$Program, [string[]]$Arguments)
    Write-Host ('> ' + $Program + ' ' + ($Arguments -join ' '))
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
try {
    Run-Checked docker @('info', '--format', '{{.ServerVersion}}')
    Run-Checked docker @('compose', 'up', '-d', '--build', '--wait')
    foreach ($release in @(@('v1', 'none'), @('v2', 'none'), @('v2-bad-crash', 'crash'))) {
        Run-Checked docker @('build', '-t', "shortly:$($release[0])", '--build-arg', "APP_VERSION=$($release[0])", '--build-arg', "BAD_RELEASE_MODE=$($release[1])", '.')
    }
    $archive = Join-Path $runtime 'shortly-images.tar'
    Run-Checked docker @('image', 'save', '-o', $archive, 'shortly:v1', 'shortly:v2', 'shortly:v2-bad-crash')
    $nodes = & kubectl --context docker-desktop get nodes -o 'jsonpath={.items[*].metadata.name}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop Kubernetes is not reachable.' }
    foreach ($nodeName in ($nodes -split '\s+')) {
        # Docker Desktop kind nodes have the same container and Kubernetes node name.
        & docker inspect $nodeName --format '{{.Name}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Run-Checked docker @('cp', $archive, "${nodeName}:/tmp/shortly-ca2-images.tar")
            Run-Checked docker @('exec', $nodeName, 'ctr', '--namespace', 'k8s.io', 'images', 'import', '/tmp/shortly-ca2-images.tar')
        } else {
            Write-Host "No kind container for $nodeName; checking whether Docker Desktop shares its image store."
        }
    }
    Write-Host 'PASS: Dockerfile images built. The Kubernetes rollout can now be started.' -ForegroundColor Green
} finally { Stop-Transcript }
