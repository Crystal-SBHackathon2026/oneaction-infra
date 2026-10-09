[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team', [string]$HelmCommand = 'helm', [string]$PythonCommand = 'python', [Parameter(Mandatory)][string]$ArtifactDirectory)
. "$PSScriptRoot/Notifications.Common.ps1"
$outputs = Get-NotificationsOutputs
$chart = Get-EsoChart -HelmCommand $HelmCommand -Directory $ArtifactDirectory
$manifests = Get-NotificationsManifests -Directory $ArtifactDirectory -PythonCommand $PythonCommand
$kubeconfig = New-EsoKubeconfig -Profile $Profile
try {
    $base = @('--kubeconfig',$kubeconfig)
    $releases = (Invoke-EsoNative $HelmCommand (@('list','-n','external-secrets','-o','json') + $base)) -join "`n" | ConvertFrom-Json
    if (@($releases | Where-Object { $_.name -eq 'external-secrets' -and $_.chart -eq 'external-secrets-2.12.0' -and $_.status -eq 'deployed' }).Count -ne 1) { throw 'The existing pinned platform ESO must remain installed.' }
    $secondary = @($releases | Where-Object { $_.name -eq 'external-secrets-argocd' })
    if ($secondary.Count -gt 0 -and $secondary[0].chart -ne 'external-secrets-2.12.0') { throw 'Review the installed Notifications ESO version first.' }
    $primary = Read-NotificationsKubeJson $kubeconfig @('-n','external-secrets','get','deployment','external-secrets','-o','json')
    if ($primary.spec.template.spec.containers[0].args -notcontains '--namespace=platform') { throw 'The primary controller namespace changed.' }
    Invoke-EsoNative 'kubectl' ($base + @('--request-timeout=30s','get','namespace','argocd','-o','name')) | Out-Host
    foreach ($crd in @('externalsecrets.external-secrets.io','secretstores.external-secrets.io')) {
        Invoke-EsoNative 'kubectl' ($base + @('wait','--for=condition=Established',"crd/$crd",'--timeout=60s')) | Out-Host
    }
    $association = (Invoke-EsoNative 'aws' @('eks','describe-pod-identity-association','--cluster-name','oneaction','--association-id',$outputs.notifications_association_id,'--profile',$Profile,'--region','ap-northeast-2','--output','json','--no-cli-pager')) -join "`n" | ConvertFrom-Json
    $a = $association.association
    if ($a.roleArn -ne $outputs.notifications_role_arn -or $a.namespace -ne 'external-secrets' -or $a.serviceAccount -ne 'external-secrets-argocd' -or $a.disableSessionTags) { throw 'Unexpected Notifications Pod Identity association.' }
    # Secret data stays in process memory only. It is never printed or saved.
    $before = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
    if (-not $before.data.ARGOCD_WEBHOOK_TOKEN -or $before.metadata.ownerReferences) { throw 'Expected the existing manually populated Argo CD Notifications Secret.' }
    # Refuse to replace a working manual token with a different source token.
    # Both payloads remain in memory and errors never include their values.
    $sourceRaw = (Invoke-EsoNative 'aws' @('secretsmanager','get-secret-value','--secret-id',$outputs.review_service_secret_arn,'--region','ap-northeast-2','--profile',$Profile,'--query','SecretString','--output','text','--no-cli-pager')) -join "`n"
    try { $source = $sourceRaw | ConvertFrom-Json } catch { throw 'Notifications source must be a JSON object; values are not included in this error.' }
    if ($source.ARGOCD_WEBHOOK_TOKEN -isnot [string] -or -not $source.ARGOCD_WEBHOOK_TOKEN -or [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source.ARGOCD_WEBHOOK_TOKEN)) -ne $before.data.ARGOCD_WEBHOOK_TOKEN) { throw 'Source and current Notifications tokens differ; reconcile them before applying ESO.' }
    $sourceRaw = $null; $source = $null
    foreach ($manifest in $manifests) {
        Invoke-EsoNative 'kubectl' ($base + @('apply','--server-side','--dry-run=server','--field-manager=oneaction-notifications-eso','-f',$manifest)) | Out-Host
    }
    # CRDs/webhook/cert-controller stay owned by the original release.
    # Its cert-controller post-renderer is intentionally not used here.
    Invoke-EsoNative $HelmCommand (@('upgrade','--install','external-secrets-argocd',$chart,'-n','external-secrets','-f',(Join-Path $EsoStack 'helm-values-argocd.yaml'),'--atomic','--wait','--timeout','5m','--history-max','3') + $base) | Out-Host
    foreach ($manifest in $manifests) {
        Invoke-EsoNative 'kubectl' ($base + @('apply','--server-side','--field-manager=oneaction-notifications-eso','-f',$manifest)) | Out-Host
    }
    Invoke-EsoNative 'kubectl' ($base + @('-n','argocd','wait','--for=condition=Ready','secretstore/review-service','externalsecret/argocd-notifications','--timeout=180s')) | Out-Host
    $after = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
    Assert-NotificationsSecretPreserved $before $after
    Write-Output 'PASS: Notifications ESO installed and token synchronized; target UID, existing keys and labels preserved.'
} finally {
    $before = $null; $after = $null; $sourceRaw = $null; $source = $null
    Remove-Item -LiteralPath $kubeconfig -ErrorAction SilentlyContinue
}
