# oneaction EKS 기반 구성

관련 작업: 이슈 #2

기존 네트워크에 EKS와 Managed Node Group을 추가하는 독립 AWS 스택입니다. Terraform 1.5.7과 AWS provider 5.100.0으로 검증합니다. Helm/Kubernetes provider를 사용하지 않으므로 클러스터 생성 전 API 접속이 필요하지 않습니다.

## 기본 구성과 선택 근거

| 항목 | 구성 |
| --- | --- |
| 계정·리전 | 123456789012 · ap-northeast-2 |
| 클러스터 | oneaction · Kubernetes 1.36 · 표준 지원 정책 |
| 네트워크 | network 상태의 Private EKS 서브넷 2개 |
| API | VPC 내부 private endpoint + 지정된 IPv4 CIDR만 public endpoint 접근 |
| 노드 | ON_DEMAND t3.medium 2대, min/desired/max=2, AL2023 x86_64 |
| 노드 SG | EKS 생성 클러스터 SG와 기존 eks-node-extra SG를 함께 연결 |
| 루트 볼륨 | 노드당 암호화 gp3 20GiB |
| 인스턴스 메타데이터 | IMDSv2 필수, hop limit=1 |
| CPU 크레딧 | standard: 크레딧 고갈 시 성능 제한, unlimited 추가 요금 방지 |
| 애드온 | VPC CNI, kube-proxy, CoreDNS, EKS Pod Identity Agent |
| 접근 권한 | 명시적인 IAM 역할의 EKS access entry; 생성자 자동 관리자 권한 없음 |
| 로그 | observability 소유 /aws/eks/oneaction/cluster 재사용, 보존 7일, 5종 로그 활성화 |

2026-10-07 서울 EKS API에서 1.36이 기본 표준 지원 버전임을 확인했습니다. 새 버전 1.37보다 기존 기본 버전을 선택했습니다. 표준 지원 종료는 2027-08-02입니다. `STANDARD` 정책은 표준 지원 종료 시 자동 업그레이드되므로 종료 전에 코드 버전과 애드온을 검토해야 합니다.

노드 2대는 기본 애드온과 초기 워크로드를 위한 개발 시작 구성입니다. 두 서브넷을 사용하지만 정확히 AZ별 한 대의 배치를 보장하는 설정은 아닙니다. 후속 워크로드의 자원 요구량을 확인한 뒤 규모를 조정합니다. 노드 업데이트 중에는 EKS가 임시 추가 노드를 만들 수 있습니다.

AWS provider 5.100에서 Standard 크레딧 설정이 전달되도록 인스턴스 타입은 Launch Template에 한 개만 명시합니다. Node Group의 타입 목록은 비워 중복 지정하지 않습니다. 타입 지정 위치는 기존 Node Group에서 변경할 수 없습니다.

배포한 애드온 버전은 `addon_versions`의 기본값에 고정합니다: VPC CNI `v1.22.4-eksbuild.3`, kube-proxy `v1.36.0-eksbuild.25`, CoreDNS `v1.14.6-eksbuild.4`, Pod Identity Agent `v1.3.10-eksbuild.3`. AWS 기본 버전이 바뀌어도 다음 plan에 자동 업그레이드가 섞이지 않도록 기본 버전 조회를 제거했습니다. 클러스터 버전 변경 시 네 애드온의 호환성을 함께 검토하고, 버전 override는 네 항목 모두 명시합니다. 빈 map이나 일부 버전만 넣는 입력은 거부합니다.

VPC CNI는 `kube-system/aws-node`만 사용할 수 있는 별도 IRSA 역할에 `AmazonEKS_CNI_Policy`를 연결합니다. 초기 네트워킹을 Pod Identity Agent의 실행과 분리하고, 일반 노드 역할에 CNI 권한을 주지 않습니다. 노드 역할에는 `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`만 연결합니다. 후속 ESO는 Pod Identity를 우선 사용하며 이 단계에서 Secrets Manager 읽기 권한을 부여하지 않습니다.

네트워킹 애드온 → Managed Node Group → CoreDNS/Pod Identity Agent 순서로 생성합니다. CoreDNS를 노드보다 먼저 완료시키려는 의존 관계를 만들지 않습니다. 기본 unmanaged 애드온의 자동 설치를 끄고 managed 애드온 생성 시 충돌을 덮어쓰지 않습니다.

## 기존 스택과 인계 문서 차이

- 백엔드는 `../backend.hcl`과 동일한 S3 버킷·DynamoDB 잠금을 사용합니다. EKS 키는 현재 상위 README 규칙의 `dev/eks/terraform.tfstate`입니다. 인계 문서의 `eks/terraform.tfstate` 예시를 사용하지 않습니다.
- network에서 `vpc_id`, `private_eks_subnet_ids`, `eks_node_extra_security_group_id`를 읽습니다. 문서의 `eks_node_extra_sg_id`와 실제 이름이 다릅니다.
- observability에서 `eks_log_group_name`을 읽고 AWS에서 이름·7일 보존을 확인합니다. 로그 그룹의 생성·import·소유권 이전을 하지 않습니다.
- 기존 서브넷 2개가 다른 AZ에 있고 같은 VPC에 속하며 private 설정·Kubernetes 태그가 유지되는지 plan의 precondition으로 확인합니다.
- 새 ALB, TargetGroupBinding, ESO, Argo CD/Argo Rollouts 설치는 후속 작업입니다. 현재 GitOps sample-app의 Ingress는 별도 ALB 생성 경로이며 플랫폼의 기존 ALB 연결과 구분합니다.

## 비용 검토

2026-10-07 기준 AWS EKS 가격표와 서울 AWS Price List API 조회값입니다. 730시간 실행 시의 추가 비용을 계산했습니다.

| 항목 | 단가 | 예상 월 비용(USD) |
| --- | --- | --- |
| EKS 표준 지원 컨트롤 플레인 | $0.10/시간 | $73.00 |
| t3.medium Linux 2대 | 대당 $0.052/시간 | $75.92 |
| gp3 루트 볼륨 40GiB | $0.0912/GB-month | $3.65 |
| 합계 | | 약 $152.57 |

세금·크레딧·환율, CloudWatch 로그 수집·저장, 기존 NAT 사용 증가와 데이터 전송 비용은 제외했습니다. 기존 ALB/RDS/NAT의 기본 요금도 이 추가 비용 표에 포함하지 않습니다. apply 전에 노드 구성과 비용을 검토합니다.

## 인증과 입력값 준비 (PowerShell)

AWS CLI v2와 Terraform 1.5.7을 PATH에 준비합니다. 현재 팀 계정은 IAM Identity Center를 사용하므로 상위 README의 `aws login` 대신 전용 SSO 프로필로 로그인합니다. SSO 서비스 리전은 us-east-1, AWS 작업 리전은 ap-northeast-2입니다.

```powershell
aws sso login --profile sbhackathon2026-team --use-device-code
$identity = aws sts get-caller-identity --profile sbhackathon2026-team --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $identity.Account -ne '123456789012') { throw '팀 계정 인증을 확인하세요.' }

# Terraform 1.5.7의 S3 backend에도 CLI의 임시 자격증명을 제공한다.
# 자격증명 값을 출력하거나 파일에 저장하지 않는다.
$credentials = aws configure export-credentials --profile sbhackathon2026-team --format process | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $credentials.SessionToken) { throw '임시 자격증명 조회 실패' }
$env:AWS_ACCESS_KEY_ID = $credentials.AccessKeyId
$env:AWS_SECRET_ACCESS_KEY = $credentials.SecretAccessKey
$env:AWS_SESSION_TOKEN = $credentials.SessionToken
$env:AWS_REGION = 'ap-northeast-2'
$env:AWS_DEFAULT_REGION = 'ap-northeast-2'
$env:TF_VAR_aws_profile = ''
$credentials = $null

Set-Location infra/eks
Copy-Item example.tfvars local.auto.tfvars
```

`local.auto.tfvars`에서 예시 IP와 IAM 역할 ARN을 실제 승인된 값으로 교체합니다. `/32`를 우선 사용하며 `/24`보다 넓은 CIDR은 거부합니다. 세션 ARN(`arn:aws:sts::...:assumed-role/...`)은 사용하지 않습니다. SSO의 현재 역할 ARN은 다음 조회로 확인할 수 있습니다.

```powershell
$roleName = ($identity.Arn -split '/')[-2]
aws iam get-role --role-name $roleName --profile sbhackathon2026-team --query Role.Arn --output text
```

Windows 시스템 프록시를 사용하는 경우 브라우저나 `Invoke-RestMethod`의 공인 IP와 `kubectl` 직접 접속의 IP가 다를 수 있습니다. 프록시 환경 변수가 없는 직접 접속에서는 `curl.exe --noproxy '*' https://checkip.amazonaws.com`으로 확인한 IPv4의 `/32`를 사용합니다. `kubectl`에 프록시를 명시했다면 해당 프록시의 실제 출구 주소를 사용해야 합니다.

작업자 공인 IP 변경 시 allowlist를 갱신하고 다시 plan합니다. 현재 GitOps 구성은 Argo CD를 `oneaction` EKS 내부에 설치하므로 설치·점검 PC의 출구 IP를 허용합니다. Argo CD의 클러스터 내부 배포에는 PC 공인 IP나 외부 Argo CD용 IAM 역할을 사용하지 않습니다. access entry의 IAM 역할이 삭제·재생성되면 ARN이 같더라도 entry 재생성 검토가 필요합니다.

## API allowlist 추가 운영

검사 도구는 [check_api_access_plan.py](scripts/check_api_access_plan.py)에 기록합니다. 이 절차는 기존 `/32`를 모두 유지하며 승인된 IPv4 `/32`만 추가합니다. 주소 제거·CIDR 확대·endpoint 방식 변경은 별도 범위로 검토합니다.

1. 위 인증 절차로 팀 계정을 확인하고 현재 allowlist와 요청 PC의 실제 출구 IPv4를 확인합니다.
2. 현재 실행에 사용하는 `local.auto.tfvars` 또는 `local.auto.tfvars.json`의 `public_access_cidrs`만 수정합니다. 기존 값을 유지하고 필요한 주소를 추가하며 관리자 역할 등 나머지 입력은 유지합니다. 두 파일을 동시에 사용하거나 초기 예시로 기존 입력을 덮어쓰지 않습니다. 이번 실행에서는 Git에서 제외된 `local.auto.tfvars.json`을 사용했습니다.
3. 다음 예시의 `$accessCidrs`를 검토한 전체 허용 목록으로 바꿉니다. Python 3의 표준 라이브러리만 필요합니다.

```powershell
Set-Location infra/eks
# 예시 주소를 그대로 적용하지 않는다. 기존 주소와 승인된 추가 주소를 모두 적는다.
$accessCidrs = @('203.0.113.10/32', '198.51.100.20/32')
terraform init '-backend-config=../backend.hcl' '-lockfile=readonly' '-input=false'
if ($LASTEXITCODE -ne 0) { throw 'init 실패' }
terraform fmt -check
if ($LASTEXITCODE -ne 0) { throw 'fmt 실패' }
terraform validate
if ($LASTEXITCODE -ne 0) { throw 'validate 실패' }
terraform plan '-input=false' '-detailed-exitcode' '-out=api-access.tfplan'
if ($LASTEXITCODE -ne 2) { throw '변경 계획을 확인하세요. NoChanges이면 적용 없이 접속 검증합니다.' }
$accessPlanJson = terraform show -json api-access.tfplan
if ($LASTEXITCODE -ne 0) { throw 'plan JSON 조회 실패' }
$accessPlanJson | Set-Content -Encoding utf8 api-access.tfplan.json
$accessCheckArgs = @('scripts/check_api_access_plan.py', 'api-access.tfplan.json')
foreach ($cidr in $accessCidrs) { $accessCheckArgs += @('--cidr', $cidr) }
python @accessCheckArgs
if ($LASTEXITCODE -ne 0) { throw 'IP 추가 외 변경 또는 허용 목록 불일치' }

# 검사한 저장 plan만 적용한다. 입력·코드·상태가 바뀌면 새 plan부터 다시 검사한다.
terraform apply '-input=false' api-access.tfplan
if ($LASTEXITCODE -ne 0) { throw 'allowlist 적용 실패' }
aws eks describe-cluster --name oneaction --region ap-northeast-2 --profile sbhackathon2026-team --query 'cluster.resourcesVpcConfig.{public:endpointPublicAccess,private:endpointPrivateAccess,cidrs:publicAccessCidrs}' --output json
if ($LASTEXITCODE -ne 0) { throw '적용 결과 조회 실패' }
./scripts/Test-ClusterReady.ps1 -Profile sbhackathon2026-team
```

계획 검사는 `oneaction`의 CIDR 목록 변경 1건만 허용하고, 기존 허용값 유지·정확한 전체 목록·두 endpoint 활성·다른 클러스터 필드 및 관리 자원·output 불변을 확인합니다. 적용 후 실제 CIDR 목록과 `ACTIVE` 상태, 기존 노드·애드온을 확인하고 새 plan이 `NoChanges`인지 확인합니다. LBC·ESO 상태도 점검합니다. 입력과 plan 파일은 Git에 올리지 않습니다.

요청 PC에서는 본인 SSO 프로필과 `oneaction` kubeconfig로 `kubectl get nodes`를 실행합니다. 운영 PC의 접속 성공이나 AWS allowlist 확인만으로 요청 PC의 인증·RBAC·출구 IP 검증까지 완료됐다고 표시하지 않습니다. 접속 장소나 모바일 네트워크가 바뀌면 `/32`를 재확인합니다.

## PR 작성 전 검증

PowerShell은 아래와 같이 파일명이 포함된 `-이름=값` 인수 전체를 인용합니다.

```powershell
terraform init '-backend-config=../backend.hcl' '-lockfile=readonly'
terraform fmt -check
terraform validate
terraform plan '-input=false' '-out=foundation.tfplan'
terraform show -json foundation.tfplan | Set-Content -Encoding utf8 foundation.tfplan.json
./scripts/Test-FoundationPlan.ps1 -PlanPath foundation.tfplan.json
./scripts/Test-FoundationPlan.Negative.ps1 -PlanPath foundation.tfplan.json
./scripts/Test-InvalidInputs.ps1
```

각 명령의 종료 코드를 확인하고 실패하면 다음 단계로 진행하지 않습니다. 검사 스크립트는 초기 foundation 계획만 허용하며 기존 자원 업데이트·삭제·교체나 범위 밖 자원의 생성을 거부합니다. 생성 후의 변경 계획은 별도 이슈에서 새 범위에 맞춰 검토해야 합니다. plan JSON과 tfvars에는 계정·네트워크 설정이 들어 있으므로 Git에서 제외합니다.

이 단계는 Terraform 구성·계획 검증입니다. 검증 결과와 plan 요약·비용을 PR에 기록하며, 노드 Ready 등 실제 실행 결과와 구분합니다. 실제 배포·동작 확인은 PR 검토 완료 후 별도 배포 단계에서 수행합니다.

## 실제 배포·동작 검증

1. 로그인·입력값·코드·기존 상태 변경이 있었다면 새 plan을 생성하고 다시 검증합니다.
2. Slack에 적용할 스택(`eks`)과 plan 요약을 공유합니다. 기존 기반 스택은 다시 apply하지 않습니다.
3. 검토한 저장 plan만 적용합니다. 클러스터 `prevent_destroy`를 해제하는 변경은 별도 검토합니다.

```powershell
terraform apply foundation.tfplan
./scripts/Test-ClusterReady.ps1 -Profile sbhackathon2026-team
./scripts/Test-ClusterNetworking.ps1 -Profile sbhackathon2026-team
```

동작 검증 스크립트는 계정, EKS·노드 그룹 ACTIVE, 원하는 수 이상의 Ready 노드, 실제 EC2의 Standard CPU 크레딧, 애드온 ACTIVE·health와 Kubernetes rollout 상태를 확인합니다. 임시 kubeconfig를 사용하며 기존 context를 변경하지 않습니다. 실패하면 원인을 분석하고 검증되지 않은 상태를 완료로 보고하지 않습니다. 배포 결과는 별도 배포 단계의 검증 기록으로 남깁니다.

네트워크 검사는 별도 임시 namespace에 DaemonSet을 생성해 각 노드에서 Pod 실행과 `kubernetes.default.svc.cluster.local` DNS 조회를 확인합니다. 테스트용 namespace와 로컬 kubeconfig·manifest는 검사 후 정리합니다. AWS Load Balancer나 외부 서비스는 생성하지 않습니다. 검사 이미지와 DNS 확인 절차는 [Kubernetes 공식 가이드](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)를 따릅니다.

## 후속 인계

`cluster_name`, `cluster_arn`, `cluster_endpoint`, `cluster_certificate_authority_data`, `cluster_security_group_id`, `node_group_name`, `node_role_arn`, `oidc_provider_arn`, `eks_log_group_name`, `addon_versions`를 제공합니다. 사람의 CLI 접속은 실제 EKS endpoint를 사용합니다. 현재 Argo CD는 같은 EKS 내부에 설치하며 Application의 `destination.server`는 `https://kubernetes.default.svc`입니다. 설치 manifest의 ServiceAccount·Kubernetes RBAC를 사용하고, UI는 `kubectl port-forward`로 접속합니다.

후속 구현 순서: AWS Load Balancer Controller → External Secrets Operator/Pod Identity → 기존 platform-tg의 TargetGroupBinding → Argo CD 연결과 GitOps 배포 검증.

## 참고

- [EKS 지원 버전](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
- [사용자 Launch Template과 보안그룹](https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html)
- [VPC CNI 전용 IRSA 역할](https://docs.aws.amazon.com/eks/latest/userguide/cni-iam-role.html)
- [EKS 가격](https://aws.amazon.com/eks/pricing/)
- [AWS Price List API](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html)
