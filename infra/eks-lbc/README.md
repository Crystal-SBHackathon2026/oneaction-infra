# AWS Load Balancer Controller

관련 작업: 이슈 #6

기존 `oneaction` EKS에 Controller를 설치하는 스택입니다. Terraform은 전용 IAM 역할과 인라인 정책만 관리하고, Kubernetes 리소스는 검증된 Helm 차트로 설치합니다.

## 구성과 인계 범위

| 항목 | 값 |
| --- | --- |
| 계정 / 리전 | `123456789012` / `ap-northeast-2` |
| 클러스터 / VPC | EKS·network 원격 상태에서 조회 |
| IAM 상태 키 | `dev/eks-lbc/terraform.tfstate` |
| Controller / Helm chart | `v3.6.0` / `3.6.0` |
| 검증 도구 | Terraform 1.5.7, AWS provider 5.100.0, AWS CLI v2, Helm 3.22.0, kubectl 1.36, Python 3 + PyYAML 6.0.3 |
| ServiceAccount | `kube-system/aws-load-balancer-controller` |
| IAM 역할 | `oneaction-aws-load-balancer-controller` |
| 복제본 / Pod 자원 | 2개, 각각 요청 50m CPU·128Mi 메모리 / 제한 250m·256Mi |
| AWS 연결 | 전용 IRSA, 지역 STS endpoint 사용 |
| 활성 경로 | ALB Ingress, TargetGroupBinding |
| 비활성 기능 | Gateway API, WAF, Shield, Service mutator webhook |

플랫폼은 기존 ALB와 `platform-tg`를 **TargetGroupBinding**으로 연결합니다. 사용자 앱은 개별 Ingress로 별도 ALB를 생성하는 경로입니다. 이번 작업에서는 Controller와 이 연동에 필요한 권한·Webhook을 준비합니다. 실제 플랫폼 Service 연결, 타깃 등록과 `/healthz` 응답은 후속 연동 작업에서 검증합니다.

노드의 IMDSv2 hop limit=1을 유지합니다. Helm에 클러스터명·리전·VPC ID를 명시하여 Controller가 노드 메타데이터에서 이를 추론하지 않게 합니다. Service mutator webhook은 이번 범위에서 LoadBalancer Service를 자동으로 NLB 관리 대상으로 바꾸지 않도록 끕니다.

## IAM과 버전 고정

`iam-policy-v3.6.0.json`은 [Controller v3.6.0 공식 정책](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.6.0/docs/install/iam_policy.json) 원본입니다. `artifacts.json`에 정책과 공식 Helm chart의 버전·SHA256을 고정하고 설치 전에 확인합니다. `.gitattributes`로 이 파일의 자동 줄바꿈 변환을 막아 Windows checkout에서도 원본 해시를 유지합니다. 설치 시 Git 저장소의 values와 Terraform outputs만 사용합니다.

IRSA trust는 기존 EKS OIDC provider, `aud=sts.amazonaws.com`, 정확한 ServiceAccount `sub`로 제한합니다. 정책은 공식 릴리스의 액션을 기반으로 다음 경계를 추가합니다.

- EC2/ELB API 호출은 서울 리전으로 제한합니다.
- 지원되는 리소스 ARN은 팀 계정과 서울 리전으로 제한합니다.
- 보안그룹 생성은 기존 VPC ARN과 팀 계정·서울 리전의 `security-group/*` ARN으로 제한합니다. `CreateSecurityGroup`은 두 리소스를 평가하므로 이 액션에 지원되지 않는 `ec2:Vpc` 조건을 붙이지 않습니다. [AWS 공식 생성 예시](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-policy-examples.html#vpc-policy-examples-security-groups)와 [EC2 권한 기준](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)을 따릅니다.
- 기존 보안그룹의 규칙 변경·삭제에는 `ec2:Vpc` 제한을 유지합니다. 태그 존재·클러스터 일치 조건도 유지합니다.
- 공식 정책의 클러스터 태그 존재 조건에는 `oneaction` 일치 조건을 추가합니다.
- 비활성 WAF·Shield 권한은 제거합니다. Secrets Manager 읽기 권한을 추가하지 않습니다.

이 정책은 Ingress의 새 ALB 생성과 기존 TargetGroupBinding 양쪽을 지원합니다. 기존 타깃 그룹 읽기만으로 모든 쓰기 권한의 동작을 검증한 것은 아닙니다. IAM 경계의 정적 검사와 실제 IRSA·ELB 읽기·Webhook 검증 결과를 함께 확인합니다.

축소한 정책은 6,683자입니다. [AWS IAM 크기 제한](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html#reference_iam-limits)에서 관리형 정책은 6,144자, 역할의 인라인 정책 합산은 10,240자입니다. 전용 역할의 인라인 정책으로 범위를 유지하며, 이 역할에는 다른 정책을 붙이지 않습니다. 향후 권한 추가 시 합산 크기와 범위를 다시 검토합니다.

## 인증과 계획 검증

도구를 PATH에 준비하고 [EKS README의 PowerShell 인증 절차](../eks/README.md#인증과-입력값-준비-powershell)로 팀 SSO 프로필의 임시 자격증명을 현재 셸에 제공합니다. 자격증명을 파일에 저장하거나 출력하지 않습니다. SSO 리전은 `us-east-1`, 작업 리전은 `ap-northeast-2`입니다.

아래 명령은 저장소 루트에서 실행합니다. `aws_profile` 기본값은 빈 문자열이며 Terraform이 현재 셸의 임시 자격증명을 사용합니다. `owner` 기본값은 공통 인프라 태그와 같은 `hyeyeon.kim`입니다.

```powershell
terraform '-chdir=infra/eks-lbc' init '-backend-config=../backend.hcl'
terraform '-chdir=infra/eks-lbc' fmt -check
terraform '-chdir=infra/eks-lbc' validate
terraform '-chdir=infra/eks-lbc' plan '-out=lbc.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'plan 실패' }
$plan = terraform '-chdir=infra/eks-lbc' show -json lbc.tfplan
if ($LASTEXITCODE -ne 0) { throw 'plan JSON 조회 실패' }
[IO.File]::WriteAllText((Join-Path (Get-Location) 'infra/eks-lbc/lbc.tfplan.json'), ($plan -join "`n"), [Text.UTF8Encoding]::new($false))
python infra/eks-lbc/scripts/check_plan.py infra/eks-lbc/lbc.tfplan.json --negative
```

계획 검사기는 전용 IAM 리소스 외의 변경, 삭제·교체, 잘못된 계정·리전·원격 상태, 넓은 IRSA trust·보안그룹 권한, 정책 크기 초과를 거부합니다. 최초 배포는 IAM 2개 생성만 있어야 합니다. 기존 정책 수정은 역할·outputs가 유지되고 `CreateSecurityGroup`의 이전 조건을 위 ARN 경계로 바꾸는 변경만 허용합니다. 다른 정책 문장·역할·정책 이름의 변경은 거부합니다. 계획이 예상 범위를 벗어나면 적용하지 않고 원인을 확인합니다. 상태·plan 파일은 Git에서 제외합니다.

## Helm 검증과 설치

렌더 검사에는 PyYAML이 필요합니다. 가상환경을 사용하면 아래처럼 준비할 수 있습니다. Helm 검증과 비교에 같은 Python 실행 파일을 지정합니다.

```powershell
python -m venv infra/eks-lbc/.venv
$python = (Resolve-Path infra/eks-lbc/.venv/Scripts/python.exe).Path
& $python -m pip install -r infra/eks-lbc/requirements-dev.txt
$artifacts = Join-Path (Get-Location) 'infra/eks-lbc/artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
./infra/eks-lbc/scripts/Test-HelmRender.ps1 -ArtifactDirectory $artifacts -PythonCommand $python -PlanPath infra/eks-lbc/lbc.tfplan.json

# 검사한 저장 계획을 적용한다. 기존 EKS 스택은 적용하지 않는다.
terraform '-chdir=infra/eks-lbc' apply lbc.tfplan
if ($LASTEXITCODE -ne 0) { throw 'IAM 적용 실패' }
./infra/eks-lbc/scripts/Install-Controller.ps1 -ArtifactDirectory $artifacts
```

설치는 `--atomic --wait --timeout 5m`을 사용합니다. 첫 설치 전에 기존 Ingress·LoadBalancer Service를 확인하고 발견하면 중단합니다. 다른 차트 버전이 설치되어 있으면 자동 업그레이드하지 않습니다. `keepTLSSecret=true`로 기존 Webhook 인증서를 유지합니다. kubeconfig와 IRSA annotation을 담은 runtime values는 임시 파일로만 생성하고 종료 시 삭제하며, 기본 kubeconfig를 바꾸지 않습니다.

[Helm CRD 관리 방식](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/)에 따라 Helm 3은 최초 설치 시 `crds/`를 설치하지만 업그레이드·제거 시 같은 방식으로 CRD를 관리하지 않습니다. 버전 변경 시 공식 릴리스와 CRD 변경을 별도로 검토해야 합니다. Helm release에는 인증서 Secret이 포함되므로 `helm get manifest` 출력이나 렌더 파일 전체를 커밋·공유하지 않습니다.

## 실제 동작과 재실행 검증

```powershell
./infra/eks-lbc/scripts/Test-Controller.ps1
./infra/eks-lbc/scripts/Test-HelmRender.ps1 -ArtifactDirectory $artifacts -PythonCommand $python -CompareInstalled
terraform '-chdir=infra/eks-lbc' plan -detailed-exitcode
if ($LASTEXITCODE -ne 0) { throw 'IAM 상태에 차이가 있음' }
```

실제 테스트는 다음을 확인합니다.

- 고정한 Helm release, Controller 2/2 Ready, 이미지·ServiceAccount와 CRD 상태
- 같은 ServiceAccount의 임시 Pod가 전용 IRSA 역할로 STS에 인증하고 기존 타깃 그룹·상태를 읽는지
- 임시 ClusterIP Service와 `TargetGroupBinding --dry-run=server`를 통해 실제 Webhook TLS 및 AWS에서 `targetType`·`vpcID` 조회가 되는지
- Controller 인증·조정 오류 유무, 테스트 전후 ALB 목록·등록 타깃 불변
- 임시 Pod·Service 정리, 설치된 Helm manifest와 서버 연결 렌더의 일치, IAM Terraform NoChanges

TGB는 서버 dry-run만 사용해 저장하지 않습니다. 타깃 등록·해제나 새 ALB 생성은 이 테스트에 포함하지 않습니다. 실제 배포 후 Kubernetes API 접근·다운로드·인증 오류가 나면 실패로 취급하며, 스크립트는 종료 시 임시 리소스와 파일을 정리합니다.

GitOps에서 이미 배포한 sample-app의 실제 Ingress 경로는 다음 읽기 전용 검사로 검증합니다. Ingress·ALB·TGB가 없으면 자동으로 만들지 않고 대기하거나 실패합니다. ALB 활성 상태, 같은 VPC의 SG, Pod IP와 일치하는 Healthy 타깃 2개, 외부 `/`·`/healthz`·`/api/info` HTTP 200과 AWS 환경 응답을 확인합니다. Application Synced/Healthy·Rollout Healthy와 노드·LBC·ESO·RDS ExternalSecret도 확인하고 임시 kubeconfig를 삭제합니다.

```powershell
./infra/eks-lbc/scripts/Test-Ingress.ps1
```

## 운영과 후속 작업

기존 EKS·네트워크·ALB 스택 소유권을 이전하지 않습니다. Controller는 현재 노드 2대에서 실행하며 이 설치 자체로 새 ALB/NLB를 만들지 않습니다. Ingress를 추가하면 별도 ALB 비용이 발생하므로 앱 연동 시 검토합니다.

장애 시 Pod 상태·로그, IRSA annotation·trust, API 접근 CIDR, Webhook endpoint·인증서를 확인합니다. Controller 제거나 IAM 역할 삭제 전에 관리 중인 Ingress·TGB와 실제 ALB·타깃을 검토해야 합니다. 이 작업의 정상 검증 범위에 제거·복구 연습을 포함하지 않습니다.

ESO·Pod Identity 구성은 완료됐습니다. 기존 `platform-tg` 연결과 플랫폼 GitOps 배포 흐름은 담당자와 함께 후속 검증합니다. sample-app의 개별 ALB 검증은 기존 플랫폼 ALB 연결 완료를 의미하지 않습니다.
