[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team', [string]$HelmCommand = 'helm', [string]$PythonCommand = 'python', [Parameter(Mandatory)][string]$ArtifactDirectory)
. "$PSScriptRoot/Common.ps1"
$outputs = Get-EsoOutputs
$chart = Get-EsoChart -HelmCommand $HelmCommand -Directory $ArtifactDirectory
$kubeconfig = New-EsoKubeconfig -Profile $Profile
$manifest = [IO.Path]::GetTempFileName()
try {
    $base = @('--kubeconfig',$kubeconfig)
    $releases = (Invoke-EsoNative $HelmCommand (@('list','-A','-o','json') + $base)) -join "`n" | ConvertFrom-Json
    $release = @($releases | Where-Object { $_.name -eq 'external-secrets' -and $_.namespace -eq 'external-secrets' })
    if ($release.Count -eq 0) {
        # Other operators' schemas may contain case-sensitive JSON keys which
        # ConvertFrom-Json cannot represent; read only the required metadata.
        $groups = Invoke-EsoNative 'kubectl' ($base + @('get','crd','-o','custom-columns=GROUP:.spec.group','--no-headers'))
        if (@($groups | Where-Object { $_.Trim() -in @('external-secrets.io','generators.external-secrets.io') }).Count -gt 0) { throw 'Existing ESO CRDs need ownership review before first install.' }
    } elseif ($release[0].chart -ne 'external-secrets-2.12.0') { throw 'Review the installed ESO version before upgrading.' }
    $association = (Invoke-EsoNative 'aws' @('eks','describe-pod-identity-association','--cluster-name','oneaction','--association-id',$outputs.association_id,'--profile',$Profile,'--region','ap-northeast-2','--output','json','--no-cli-pager')) -join "`n" | ConvertFrom-Json
    $a = $association.association
    if ($a.roleArn -ne $outputs.role_arn -or $a.namespace -ne 'external-secrets' -or $a.serviceAccount -ne 'external-secrets' -or $a.disableSessionTags) { throw 'Unexpected Pod Identity association.' }
    $namespaces = (Invoke-EsoNative 'kubectl' ($base + @('get','namespaces','-o','json'))) -join "`n" | ConvertFrom-Json
    if (@($namespaces.items | Where-Object { $_.metadata.name -eq 'platform' }).Count -eq 0) {
        Invoke-EsoNative 'kubectl' ($base + @('create','namespace','platform'))
    }
    Invoke-EsoNative $HelmCommand (@('upgrade','--install','external-secrets',$chart,'-n','external-secrets','--create-namespace','-f',(Join-Path $EsoStack 'helm-values.yaml'),'--post-renderer',$PythonCommand,'--post-renderer-args',"$PSScriptRoot/post_renderer.py",'--atomic','--wait','--timeout','5m','--history-max','3') + $base)
    foreach ($crd in @('externalsecrets.external-secrets.io','secretstores.external-secrets.io')) {
        Invoke-EsoNative 'kubectl' ($base + @('wait','--for=condition=Established',"crd/$crd",'--timeout=60s'))
    }
    # Read metadata only; never export Kubernetes Secret data to a file.
    $existingSecrets = (Invoke-EsoNative 'kubectl' ($base + @('-n','platform','get','secrets','-o','custom-columns=NAME:.metadata.name','--no-headers'))) -join "`n"
    if ($existingSecrets -match '(?m)^review-db-credentials\s*$') {
        $owner = (Invoke-EsoNative 'kubectl' ($base + @('-n','platform','get','secret','review-db-credentials','-o','jsonpath={.metadata.ownerReferences[0].name}'))) -join ''
        if ($owner -ne 'review-db') { throw 'Existing target Secret has another owner; do not overwrite it.' }
    }
    Write-EsoSyncManifest -SecretArn $outputs.secret_arn -Path $manifest
    Invoke-EsoNative 'kubectl' ($base + @('apply','--server-side','--field-manager=oneaction-eks-eso','-f',$manifest))
    Invoke-EsoNative 'kubectl' ($base + @('-n','platform','wait','--for=condition=Ready','secretstore/review-db','--timeout=180s'))
    Invoke-EsoNative 'kubectl' ($base + @('-n','platform','wait','--for=condition=Ready','externalsecret/review-db','--timeout=180s'))
} finally { Remove-Item -LiteralPath $manifest, $kubeconfig }
