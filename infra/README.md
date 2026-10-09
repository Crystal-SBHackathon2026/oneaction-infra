# oneaction AWS 기반 인프라

공통 AWS 리소스와 EKS 구성을 상태 키별 Terraform 스택으로 관리합니다.

## 전제

- AWS Region: `ap-northeast-2`
- Terraform 1.5.7: S3 상태 잠금에 DynamoDB `oneaction-terraform-locks` 사용
- 공통 태그: `Project=oneaction`, `Owner=hyeyeon.kim`, `Env=dev`

## 인증과 실행

각 팀원은 자신의 AWS CLI 프로필로 로그인합니다.

```bash
aws login --region ap-northeast-2 --profile <profile>
eval "$(aws configure export-credentials --profile <profile> --format env)"
```

각 스택에서 다음 순서로 실행합니다.

```bash
terraform init -backend-config=../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

적용 순서:

1. `network`
2. `storage`
3. `dns` — 실제 소유 도메인이 필요함
4. `database`
5. `alb`
6. `observability`

상태 키는 `dev/<stack>/terraform.tfstate`로 분리되어 있습니다. EKS는 `infra/eks/`와 `dev/eks/terraform.tfstate`를 추가해 독립적으로 관리하세요.

EKS 배포 후 구성은 다음 문서에서 확인합니다.

- [EKS 기반 구성·배포 검증](eks/README.md): `dev/eks/terraform.tfstate`
- [AWS Load Balancer Controller·전용 IAM](eks-lbc/README.md): `dev/eks-lbc/terraform.tfstate`
- [External Secrets Operator·Pod Identity·RDS Secret 동기화](eks-eso/README.md): `dev/eks-eso/terraform.tfstate`
- [MSK·검토 서비스 Kafka](msk/): `dev/msk/terraform.tfstate` — `kafka.t3.small` 2대, 데이터 서브넷, PLAINTEXT 9092는 Private EKS 서브넷에서만. output `bootstrap_brokers`를 검토 서비스 `KAFKA_BOOTSTRAP`에 넣는다

## 미완료 외부 입력

- 실제 Route 53 도메인
- SNS 구독 이메일

현재 ALB는 도메인이 없어 HTTP 80 임시 모드입니다. 실제 도메인과 ACM 인증서가 준비되면 `alb` 스택의 `certificate_arn`, `hosted_zone_id`, `domain_name`을 전달해 HTTPS로 전환합니다.
