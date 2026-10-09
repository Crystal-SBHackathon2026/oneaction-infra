# External Secrets Operator · EKS Pod Identity

관련 작업: 이슈 #8, GitOps 접근·토큰 읽기 이슈 #10, LBC·Claude Secret 권한 이슈 #13, Notifications 자동 동기화 이슈 #15

기존 `oneaction` EKS에서 지정된 RDS Secret을 `platform` namespace의 Kubernetes Secret으로 동기화합니다. Terraform은 전용 IAM 역할·읽기 정책·Pod Identity 연결만 관리합니다. ESO와 CRD는 Helm, SecretStore·ExternalSecret은 별도 manifest로 관리합니다.

## 구성

| 항목 | 값 |
| --- | --- |
| 계정 / 작업 리전 / 클러스터 | `123456789012` / `ap-northeast-2` / `oneaction` |
| Terraform 상태 | `dev/eks-eso/terraform.tfstate` |
| 참조 상태 | `dev/eks/terraform.tfstate`, `dev/database/terraform.tfstate` |
| IAM 역할 / 인라인 정책 | `oneaction-external-secrets` / `read-review-db-secret`, `read-gitops-token-secret`, `read-review-service-secret` |
| Pod Identity ServiceAccount | `external-secrets/external-secrets` |
| ESO Helm release | `external-secrets/external-secrets` |
| Chart / image | `2.12.0` / `ghcr.io/external-secrets/external-secrets:v2.12.0` |
| SecretStore / ExternalSecret | `platform/review-db` / `platform/review-db` |
| 생성되는 Kubernetes Secret | `platform/review-db-credentials` |
| 동기화하는 키 / 주기 | `username`, `password` / `Periodic`, 1시간 |

검증 도구는 Terraform 1.5.7, AWS provider 5.100.0, AWS CLI v2, kubectl 1.36, Helm 3.22.0, Python 3 + PyYAML 6.0.3입니다. 차트 버전과 SHA256은 [artifacts.json](artifacts.json)에 고정하고 설치 전에 확인합니다.

| Deployment | 복제본 | Pod 요청 CPU / 메모리 | Pod 제한 CPU / 메모리 |
| --- | --- | --- | --- |
| external-secrets | 1 | 50m / 128Mi | 250m / 256Mi |
| external-secrets-webhook | 1 | 25m / 64Mi | 100m / 128Mi |
| external-secrets-cert-controller | 1 | 25m / 64Mi | 100m / 128Mi |

전체 요청은 100m CPU·256Mi 메모리이며 현재 개발 노드 2대에서 실행합니다. 복제본 1개씩의 개발 구성입니다. 일시적인 Controller 중단 시 기존 Kubernetes Secret은 남지만 동기화가 지연되고, Webhook 중단 시 SecretStore·ExternalSecret 변경 요청이 실패할 수 있습니다. 새 노드·ALB·RDS·KMS key는 생성하지 않습니다.

## AWS 인증과 권한

[EKS Pod Identity 방식](https://external-secrets.io/latest/provider/aws-access/)으로 Operator Pod의 기본 AWS credential chain을 사용합니다. SecretStore에 `auth`·`serviceAccountRef`를 넣거나 ServiceAccount에 IRSA role annotation을 함께 붙이지 않습니다. 기존 EKS Pod Identity Agent를 사용합니다.

IAM trust는 `pods.eks.amazonaws.com`의 `sts:AssumeRole`, `sts:TagSession`과 아래 세 [요청 세션 태그](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html)를 정확히 제한합니다.

- 클러스터 ARN: `arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction`
- namespace: `external-secrets`
- ServiceAccount: `external-secrets`

연결의 session tags를 끄지 않습니다. 기존 RDS 읽기 정책은 database 원격 상태의 `db_master_user_secret_arn` 하나에만 `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret`을 허용하고 호출 리전도 서울로 제한합니다. 이 RDS 정책에는 Secret 쓰기·삭제·회전이나 다른 Secret 읽기를 추가하지 않습니다. 별도 관리형 정책도 추가하지 않습니다. SecretStore의 표시상 `ReadWrite` capabilities는 provider가 지원하는 기능이며 실제 IAM 정책에 쓰기 권한이 있다는 뜻이 아닙니다.

현재 Secret은 AWS 관리형 키를 사용하여 별도 `kms:Decrypt` 권한을 추가하지 않았습니다. Terraform은 Secret 메타데이터만 읽고 `aws_secretsmanager_secret_version`을 사용하지 않습니다. customer-managed KMS key가 감지되면 plan을 중단하며, 해당 키의 복호화 권한은 별도로 검토합니다.

GitOps 토큰 Secret의 추가 읽기는 별도 `read-gitops-token-secret` 정책으로 적용·검증했습니다. `gitops_token_secret_arn` 기본값에는 확인한 `oneaction/gitops-token`의 전체 ARN을 반영했습니다. 기존 RDS 정책을 유지하고 토큰 Secret ARN 한 개에만 같은 읽기 API를 허용합니다. 정책 검사에도 `--gitops-token-secret-arn`으로 확인한 ARN을 전달합니다. 토큰 값·GitHub 접근 권한·worker 연결은 앱/GitOps 담당 구성입니다.

Claude Secret은 `read-review-service-secret` 정책으로 추가합니다. 연결 예시는 팀 메인 페이지의 결과 보고서 아래 review-service Secret 연결 가이드 — Notion에 정리합니다. `review_service_secret_arn`에는 확인한 `oneaction/review-service`의 전체 ARN 한 개를 사용하고, 검사에도 `--review-service-secret-arn`을 전달합니다. 기존 역할·두 정책·Pod Identity와 namespace RBAC를 유지합니다. 영구 `review-service-secrets` ExternalSecret과 worker 연결은 앱/GitOps 담당 구성입니다.

## Kubernetes 권한과 필수 post-renderer

Operator의 Secret 권한은 `platform` Role로 제한합니다. ClusterSecretStore·ClusterExternalSecret·ClusterGenerator·PushSecret 계열 기능을 비활성화하며 서비스 계정 토큰 생성 권한과 aggregate RBAC도 끕니다. 차트의 namespaced generator CRD는 포함되지만 이번 동기화에서 사용하지 않습니다.

공식 차트 2.12.0의 cert-controller ClusterRole에는 전체 namespace의 Secret 읽기·인증서 Secret 수정 권한이 포함됩니다. [post_renderer.py](scripts/post_renderer.py)가 두 Secret 규칙을 `external-secrets` namespace의 Role·RoleBinding으로 옮깁니다. CRD·Webhook 인증서 관리에 필요한 나머지 ClusterRole 규칙은 유지합니다. 고정 차트의 규칙 형태가 달라지면 renderer가 실패하도록 했습니다.

**설치·업그레이드·렌더 비교에는 항상 이 저장소의 동일한 post-renderer를 사용합니다.** [Helm의 post-renderer 지침](https://helm.sh/docs/topics/advanced/#post-rendering)처럼 다른 명령으로 renderer를 생략하면 권한이 다시 넓어질 수 있습니다. 현재 release의 CRD는 chart template에 포함되므로 버전 변경·제거 시 기존 Custom Resource와 생성된 Secret의 소유권을 함께 검토합니다. 일반 Helm `crds/` 디렉터리와 동일한 수명주기로 가정하지 않습니다.

## 계획·렌더 검사와 설치

도구를 PATH에 준비하고 [EKS README의 PowerShell 인증 절차](../eks/README.md#인증과-입력값-준비-powershell)로 팀 SSO 프로필의 임시 자격증명을 현재 셸에 제공합니다. SSO 리전은 `us-east-1`, 작업 리전은 `ap-northeast-2`입니다. 아래 명령은 저장소 루트에서 실행하고 각 실패 시 다음 단계로 넘어가지 않습니다.

```powershell
terraform '-chdir=infra/eks-eso' init '-backend-config=../backend.hcl' '-lockfile=readonly'
terraform '-chdir=infra/eks-eso' fmt -check
terraform '-chdir=infra/eks-eso' validate
terraform '-chdir=infra/eks-eso' plan '-out=eso.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'plan 실패' }
$plan = terraform '-chdir=infra/eks-eso' show -json eso.tfplan
if ($LASTEXITCODE -ne 0) { throw 'plan JSON 조회 실패' }
[IO.File]::WriteAllText((Join-Path (Get-Location) 'infra/eks-eso/eso.tfplan.json'), ($plan -join "`n"), [Text.UTF8Encoding]::new($false))

python -m venv infra/eks-eso/.venv
$python = (Resolve-Path infra/eks-eso/.venv/Scripts/python.exe).Path
& $python -m pip install -r infra/eks-eso/requirements-dev.txt
$gitopsSecretArn = 'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/gitops-token-AbCdEf'
$reviewSecretArn = 'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-GhIjKl'
& $python infra/eks-eso/scripts/check_plan.py infra/eks-eso/eso.tfplan.json --gitops-token-secret-arn $gitopsSecretArn --review-service-secret-arn $reviewSecretArn --negative
if ($LASTEXITCODE -ne 0) { throw '계획 안전성 검사 실패' }
$artifacts = Join-Path (Get-Location) 'infra/eks-eso/artifacts'
./infra/eks-eso/scripts/Test-HelmRender.ps1 -ArtifactDirectory $artifacts -PythonCommand $python

# 현재 적용된 IAM 구성은 NoChanges여야 한다. 추가 Secret의 최초 권한 적용은 정책 1개 생성만 허용한다.
terraform '-chdir=infra/eks-eso' apply eso.tfplan
if ($LASTEXITCODE -ne 0) { throw 'IAM 적용 실패' }
./infra/eks-eso/scripts/Install-Eso.ps1 -ArtifactDirectory $artifacts -PythonCommand $python
```

계획 검사기는 계정·리전·상태 키·권한 범위, 삭제·교체와 범위 밖 변경을 거부합니다. EKS·database·network·ALB 스택은 이 설치 명령에서 apply하지 않습니다. 상태·plan·artifact·가상환경 파일은 Git에서 제외합니다.

설치는 `--atomic --wait --timeout 5m`을 사용합니다. 기존 다른 버전의 release, 첫 설치 전 이미 존재하는 ESO CRD, 다른 소유자의 target Secret이 있으면 자동으로 덮어쓰지 않습니다. `platform` namespace가 없을 때 생성합니다. `secret-sync.yaml`의 `__RDS_SECRET_ARN__`만 실제 Terraform output으로 치환해 임시 파일로 적용하고 종료 시 삭제합니다. 비밀번호 payload는 이 파일에 넣지 않습니다. SecretStore·ExternalSecret 적용은 Helm 성공 후 별도 실행하므로 실패 시 먼저 두 리소스의 상태를 확인합니다.

## 실제 테스트와 재검증

```powershell
./infra/eks-eso/scripts/Test-Eso.ps1
./infra/eks-eso/scripts/Test-HelmRender.ps1 -ArtifactDirectory $artifacts -PythonCommand $python -CompareInstalled
terraform '-chdir=infra/eks-eso' plan -detailed-exitcode
if ($LASTEXITCODE -ne 0) { throw 'ESO IAM 상태에 차이가 있음' }
```

테스트는 실제 클러스터에서 다음을 확인합니다.

- 세 Deployment의 rollout·고정 이미지, ServiceAccount의 Pod Identity 사용, namespace별 Secret 접근 허용·거부
- 같은 ServiceAccount를 사용하는 임시 Pod에서 실제 STS 역할 확인, 지정 Secret 메타데이터 읽기, 다른 ARN의 접근 거부. GitOps ARN이 설정된 경우 현재 버전의 GetSecretValue 성공도 확인하며 토큰 내용은 출력·저장하지 않음
- Claude ARN이 설정된 경우 같은 Pod Identity의 현재 버전 읽기와 임시 ExternalSecret의 JSON `ANTHROPIC_API_KEY` 동기화, non-root 소비 Pod의 비어 있지 않은 키 사용 확인. API 키 값은 출력하거나 로컬·Terraform·Git에 저장하지 않으며 영구 앱 Secret은 수정하지 않음
- 실제 Webhook server dry-run, SecretStore·ExternalSecret Ready, 두 키와 ESO 소유권 확인, 강제 재동기화
- 임시 non-root Pod가 동기화된 두 키를 읽을 수 있는지 성공 여부만 출력
- 원본 RDS Secret의 version/stage 불변, 관찰한 인증·RBAC 오류 없음, 임시 Pod와 파일 정리
- Claude 검증용 ExternalSecret·생성 Secret·소비 Pod 정리

기본 kubeconfig·context를 바꾸거나 로컬 자격증명을 Pod에 전달하지 않습니다. `kubectl get secret -o yaml/json`, Secret decoding, `GetSecretValue` 직접 출력과 전체 Helm manifest 공유는 사용하지 않습니다. 테스트는 동기화·마운트·값 사용 확인이며 실제 애플리케이션의 PostgreSQL 접속·SQL 실행이나 비밀번호 회전 연습은 포함하지 않습니다.

## 앱 연동과 갱신

앱은 `platform` namespace에서 `review-db-credentials`의 `username`, `password`를 `secretKeyRef` 또는 read-only volume으로 참조합니다. hostname·port·database는 비밀값이 아니므로 database 스택 output 값으로 별도 설정합니다. 앱 Pod에 ESO의 ServiceAccount나 IAM 역할을 재사용하지 않습니다.

ESO는 [1시간마다 갱신](https://external-secrets.io/latest/api/externalsecret/)합니다. 필요 시 다음 명령으로 즉시 재동기화합니다.

```powershell
kubectl -n platform annotate externalsecret review-db "force-sync=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())" --overwrite
kubectl -n platform get secretstore review-db
kubectl -n platform get externalsecret review-db
```

Secret을 환경변수로 받은 실행 중인 컨테이너는 새 값을 쓰려면 재시작이 필요합니다. 일반 Secret volume은 갱신을 전달하지만 앱이 파일을 다시 읽어야 하며 `subPath` mount는 자동 갱신되지 않습니다. [Kubernetes Secret 갱신 동작](https://kubernetes.io/docs/concepts/configuration/secret/#using-secrets-as-files-from-a-pod)을 기준으로 앱 배포·연결 풀 갱신을 함께 설계합니다. 이번 작업에서 자동 rollout 기능은 추가하지 않습니다.

`creationPolicy: Owner`로 ExternalSecret이 생성된 Kubernetes Secret을 소유합니다. `deletionPolicy: Retain`은 원격 Secret 누락 시의 보존 정책이며 ExternalSecret 자체 삭제에 대한 보존 보장은 아닙니다. 삭제·GitOps prune 전 소비 중인 앱과 owner reference를 확인합니다.

ESO release와 동기화 manifest는 현재 인프라 작업에서 관리합니다. GitOps 저장소에 중복 ESO 설치나 같은 리소스의 다른 필드 관리자를 추가하기 전에 소유권을 정리합니다. 다음 단계에서 기존 ALB TargetGroupBinding과 Argo CD 접속을 검증하고 인계 문서를 완성합니다.

## Argo CD Notifications 자동 동기화

기존 `platform` 컨트롤러를 유지하고 `external-secrets` namespace에 `external-secrets-argocd` Helm release를 추가합니다. [고정 버전 소스](https://github.com/external-secrets/external-secrets/blob/v2.12.0/cmd/controller/root.go)에서 감시 namespace는 단일 문자열입니다. 새 release는 `argocd`만 감시하고 CRD·Webhook·cert-controller는 기존 release가 계속 관리합니다. `ClusterSecretStore`와 cluster/push reconciler는 사용하지 않습니다.

| 항목 | 값 |
| --- | --- |
| 새 release / ServiceAccount | `external-secrets/external-secrets-argocd` |
| IAM 역할 | `oneaction-external-secrets-argocd` |
| AWS 읽기 범위 | 지정 `oneaction/review-service` Secret ARN 하나, `GetSecretValue`·`DescribeSecret`, 서울 리전 |
| Kubernetes 읽기·쓰기 범위 | `argocd`의 ESO 리소스·Secret, 다른 namespace의 Secret 권한 없음 |
| SecretStore / ExternalSecret | `argocd/review-service` / `argocd/argocd-notifications` |
| 대상 Secret / 키 | 기존 `argocd/argocd-notifications-secret` / `ARGOCD_WEBHOOK_TOKEN` |
| 소유권 / 갱신 | `Merge`·`Retain`, 1시간 주기 |
| 추가 Pod 자원 | 요청 50m / 128Mi, 제한 250m / 256Mi, 복제본 1 |

Terraform은 기존 `dev/eks-eso/terraform.tfstate`에서 별도 IAM 역할·읽기 정책·Pod Identity 3개를 관리합니다. 기존 플랫폼 역할의 DB·GitOps·Claude Secret 읽기 정책은 유지합니다. IAM은 JSON 속성 하나에 권한을 제한할 수 없으므로 원격 Secret ARN을 제한하고, ExternalSecret이 토큰 속성 하나만 Kubernetes에 저장합니다.

동기화 입력은 GitOps PR #19의 파일입니다. [notifications-artifacts.json](notifications-artifacts.json)에 원본 커밋·SHA256을 고정하고 다운로드 후 내용도 검증합니다. 이 저장소에 연결 예시나 두 번째 manifest 사본을 만들지 않습니다. 원본 파일의 플랫폼 SA 설명은 최초 수동 관리 시점의 설명이며, 이 구성에서는 새 컨트롤러 SA의 Pod Identity가 사용됩니다. GitOps에서 같은 리소스를 관리하게 될 때는 필드 관리자·prune 소유권을 먼저 맞춥니다.

설치 전에는 원격 토큰과 현재 수동 토큰을 메모리에서 비교하여 다르면 중단합니다. Secret 값·전체 JSON은 파일·로그로 남기지 않습니다. `Merge`로 기존 Secret의 UID·키·라벨을 보존하며 새 owner reference를 붙이지 않습니다. 기존 키가 없는 첫 설치는 이 절차로 처리하지 않습니다.

```powershell
# Terraform 임시 자격증명을 현재 프로세스에 준비한 뒤 실행한다.
terraform '-chdir=infra/eks-eso' fmt -check
terraform '-chdir=infra/eks-eso' init '-backend-config=../backend.hcl' '-lockfile=readonly'
terraform '-chdir=infra/eks-eso' validate
terraform '-chdir=infra/eks-eso' plan '-out=notifications.tfplan'
terraform '-chdir=infra/eks-eso' show -json notifications.tfplan | Set-Content -Encoding utf8 infra/eks-eso/notifications.tfplan.json
python -B infra/eks-eso/scripts/check_notifications_plan.py infra/eks-eso/notifications.tfplan.json
# 새 Notifications 리소스 3개 생성, 기존 리소스 변경 없음 확인 후 적용
terraform '-chdir=infra/eks-eso' apply notifications.tfplan

./infra/eks-eso/scripts/Test-NotificationsHelmRender.ps1 -ArtifactDirectory '<artifact-dir>'
./infra/eks-eso/scripts/Install-NotificationsEso.ps1 -ArtifactDirectory '<artifact-dir>'
./infra/eks-eso/scripts/Test-NotificationsEso.ps1 -ArtifactDirectory '<artifact-dir>' -CheckRetain
./infra/eks-eso/scripts/Test-NotificationsEso.ps1 -ArtifactDirectory '<artifact-dir>' -CheckPopulate
./infra/eks-eso/scripts/Test-NotificationsHelmRender.ps1 -ArtifactDirectory '<artifact-dir>' -CompareInstalled
```

위 명령은 Terraform·AWS CLI·kubectl·Helm·Python/PyYAML이 PATH에 있는 PowerShell 환경 기준입니다. Helm·Python 경로는 각 스크립트의 `-HelmCommand`·`-PythonCommand`로 지정할 수 있습니다. 원본 플랫폼 release의 렌더 비교에는 기존 `Test-HelmRender.ps1 -CompareInstalled`와 post-renderer를 계속 사용합니다. **새 release에 기존 cert-controller post-renderer를 사용하면 실패합니다.**

적용 후 plan은 `check_notifications_plan.py <plan.json> --phase steady`로 검사합니다. 실행 검증은 전용 SA의 실제 STS 역할과 Secret 읽기·범위 밖 거부, namespace RBAC, 강제 재동기화, 기존 서비스의 Ready·HTTP 응답을 확인합니다. `-CheckRetain`은 ExternalSecret만 잠시 삭제하고 대상 Secret 보존을 확인한 뒤 `finally`에서 원본 manifest를 다시 적용합니다. 대상 Secret은 삭제하지 않습니다.

`-CheckPopulate`는 같은 argocd 컨트롤러·SecretStore·remoteRef·Merge 정책을 사용하는 별도 임시 Secret에서 최초 토큰 채움과 해당 임시 키 제거 후 재동기화를 확인합니다. 임시 대상의 UID·기존 sentinel 키·라벨과 운영 Notifications Secret을 보존하고 테스트 리소스는 정리합니다. 수동 키와 원격 키가 같은 상황에서도 실제 ESO 쓰기를 입증할 수 있으며 운영 토큰을 비우는 단계는 필요하지 않습니다. 자격증명 값은 메모리에서 비교하고 출력·파일 저장하지 않습니다.

전환 후 해당 키는 ESO가 관리합니다. 토큰 갱신은 원격 Secret에서 진행하고 기존 수동 patch 절차를 같은 키에 반복 적용하지 않습니다.

롤백은 `argocd/argocd-notifications` ExternalSecret을 제거하고 기존 Secret의 UID·키·라벨이 유지되는지 확인한 뒤 새 `external-secrets-argocd` release만 제거합니다. 원본 `external-secrets` release·CRD·Webhook과 대상 Secret을 제거하지 않습니다. 이후 자동 갱신은 중단되므로 토큰 회전은 팀의 기존 수동 절차로 맞춥니다. `review_service_secret_arn = null`은 기존 플랫폼 읽기 정책도 비활성화하므로 Notifications만 롤백하는 용도로 사용하지 않습니다.

Notifications의 실제 알림 페이로드·baseline 처리와 API의 중복·순서 역전 방지는 GitOps·review-service 담당 범위입니다. ESO 전환 검증을 위해 앱의 `deploy.yaml`을 삭제하거나 새 시험 PR을 만들 필요는 없습니다.
