. "$PSScriptRoot/Common.ps1"

function Get-NotificationsOutputs {
    $values = Get-EsoOutputs
    if ($values.notifications_role_arn -ne 'arn:aws:iam::123456789012:role/oneaction-external-secrets-argocd' -or
        -not $values.notifications_association_id -or
        $values.notifications_operator_namespace -ne 'external-secrets' -or
        $values.notifications_service_account -ne 'external-secrets-argocd' -or
        $values.notifications_target_namespace -ne 'argocd' -or
        $values.review_service_secret_arn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-[A-Za-z0-9]{6}$') {
        throw 'Apply and verify the reviewed Notifications IAM/Pod Identity resources first.'
    }
    return $values
}

function Get-NotificationsManifests {
    param([string]$Directory, [string]$PythonCommand)
    $pins = Get-Content -LiteralPath (Join-Path $EsoStack 'notifications-artifacts.json') -Raw | ConvertFrom-Json
    if ($pins.repository -ne 'Crystal-SBHackathon2026/gitops' -or $pins.revision -notmatch '^[a-f0-9]{40}$') { throw 'Unexpected Notifications manifest source.' }
    $directoryPath = Join-Path $Directory "notifications/$($pins.revision)"
    New-Item -ItemType Directory -Path $directoryPath -Force | Out-Null
    $paths = @()
    foreach ($name in @('secretstore.yaml','externalsecret.yaml')) {
        $path = Join-Path $directoryPath $name
        if (-not (Test-Path -LiteralPath $path)) {
            Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$($pins.repository)/$($pins.revision)/argocd/notifications/$name" -OutFile $path -TimeoutSec 30
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins.files.$name) { throw 'Notifications manifest checksum mismatch.' }
        $paths += $path
    }
    Invoke-EsoNative $PythonCommand (@('-B',"$PSScriptRoot/check_notifications_manifests.py") + $paths) | Out-Host
    return $paths
}

function Read-NotificationsKubeJson {
    param([string]$Kubeconfig, [string[]]$Arguments)
    return ((Invoke-EsoNative 'kubectl' (@('--kubeconfig',$Kubeconfig,'--request-timeout=30s') + $Arguments)) -join "`n" | ConvertFrom-Json)
}

function Assert-NotificationsSecretPreserved {
    param($Before, $After)
    if ($Before.metadata.uid -ne $After.metadata.uid) { throw 'Notifications target Secret was replaced.' }
    foreach ($label in $Before.metadata.labels.PSObject.Properties) {
        if ($After.metadata.labels.($label.Name) -ne $label.Value) { throw 'An existing Notifications Secret label changed.' }
    }
    foreach ($key in $Before.data.PSObject.Properties) {
        if ($After.data.($key.Name) -ne $key.Value) { throw 'An existing Notifications Secret key changed; inspect token/source consistency without printing values.' }
    }
    if (-not $After.data.ARGOCD_WEBHOOK_TOKEN -or $After.metadata.ownerReferences) { throw 'Notifications Merge target must contain its token without an ExternalSecret owner reference.' }
}

function Wait-NotificationsRefresh {
    param([string]$Kubeconfig, [string]$Namespace, [string]$Name)
    $before = Read-NotificationsKubeJson $Kubeconfig @('-n',$Namespace,'get','externalsecret',$Name,'-o','json')
    Invoke-EsoNative 'kubectl' @('--kubeconfig',$Kubeconfig,'--request-timeout=30s','-n',$Namespace,'annotate','externalsecret',$Name,"force-sync=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())",'--overwrite') | Out-Host
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 180) {
        $after = Read-NotificationsKubeJson $Kubeconfig @('-n',$Namespace,'get','externalsecret',$Name,'-o','json')
        # ESO records refreshTime to seconds. Its syncedResourceVersion also
        # includes the force-sync annotation hash, so same-second refreshes count.
        $refreshed = $after.status.refreshTime -ne $before.status.refreshTime -or
            ($after.status.syncedResourceVersion -and $after.status.syncedResourceVersion -ne $before.status.syncedResourceVersion)
        if ($refreshed -and @($after.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1) { return }
        Start-Sleep -Seconds 2
    }
    throw "ExternalSecret refresh did not complete: $Namespace/$Name."
}

function Test-NotificationsMergePopulate {
    param([string]$Kubeconfig, [string]$ExpectedToken)
    if (-not $ExpectedToken) { throw 'A working Notifications token is required for the population comparison.' }
    $name = 'notifications-populate-' + [guid]::NewGuid().ToString('N').Substring(0,10)
    $secretPath = [IO.Path]::GetTempFileName()
    $externalPath = [IO.Path]::GetTempFileName()
    $patchPath = [IO.Path]::GetTempFileName()
    $secretAttempted = $false; $externalAttempted = $false
    $sentinel = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('keep-probe-sentinel'))
    $base = @('--kubeconfig',$Kubeconfig,'--request-timeout=30s','-n','argocd')
    try {
        # Only the disposable target is written/depleted. These files contain
        # public metadata and a non-secret sentinel, never a credential value.
        $secret = @{apiVersion='v1';kind='Secret';metadata=@{name=$name;namespace='argocd';labels=@{'oneaction.crystal/test'='notifications-populate'}};type='Opaque';data=@{ONEACTION_PROBE_SENTINEL=$sentinel}}
        $external = @{apiVersion='external-secrets.io/v1';kind='ExternalSecret';metadata=@{name=$name;namespace='argocd'};spec=@{
            refreshInterval='1h';secretStoreRef=@{name='review-service';kind='SecretStore'}
            target=@{name=$name;creationPolicy='Merge';deletionPolicy='Retain'}
            data=@(@{secretKey='ARGOCD_WEBHOOK_TOKEN';remoteRef=@{key='oneaction/review-service';property='ARGOCD_WEBHOOK_TOKEN'}})
        }}
        Write-EsoJson $secret $secretPath; Write-EsoJson $external $externalPath
        Write-EsoJson @(@{op='remove';path='/data/ARGOCD_WEBHOOK_TOKEN'}) $patchPath
        $secretAttempted = $true
        Invoke-EsoNative 'kubectl' ($base + @('create','-f',$secretPath)) | Out-Host
        $initial = Read-NotificationsKubeJson $Kubeconfig @('-n','argocd','get','secret',$name,'-o','json')
        $externalAttempted = $true
        Invoke-EsoNative 'kubectl' ($base + @('create','-f',$externalPath)) | Out-Host
        Invoke-EsoNative 'kubectl' ($base + @('wait','--for=condition=Ready',"externalsecret/$name",'--timeout=180s')) | Out-Host
        foreach ($round in 1..2) {
            if ($round -eq 2) {
                Invoke-EsoNative 'kubectl' ($base + @('patch','secret',$name,'--type=json','--patch-file',$patchPath)) | Out-Host
                Wait-NotificationsRefresh $Kubeconfig 'argocd' $name
            }
            $populated = Read-NotificationsKubeJson $Kubeconfig @('-n','argocd','get','secret',$name,'-o','json')
            Assert-NotificationsSecretPreserved $initial $populated
            if ($populated.data.ARGOCD_WEBHOOK_TOKEN -ne $ExpectedToken) { throw 'The disposable Merge target token does not match the working Notifications token; values were not printed.' }
        }
        Write-Output 'PASS: dedicated ESO populates and restores the disposable Merge target token while preserving its UID, sentinel and labels.'
    } finally {
        $initial = $null; $populated = $null; $ExpectedToken = $null
        # Try both cleanups even when one Kubernetes request fails.
        try {
            if ($externalAttempted) { Invoke-EsoNative 'kubectl' ($base + @('delete','externalsecret',$name,'--ignore-not-found','--wait=true','--timeout=60s')) | Out-Host }
        } finally {
            try {
                if ($secretAttempted) { Invoke-EsoNative 'kubectl' ($base + @('delete','secret',$name,'--ignore-not-found','--wait=true','--timeout=60s')) | Out-Host }
            } finally { Remove-Item -LiteralPath $secretPath,$externalPath,$patchPath -ErrorAction SilentlyContinue }
        }
    }
}
