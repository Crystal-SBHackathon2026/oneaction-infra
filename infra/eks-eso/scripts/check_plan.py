"""Reject wider AWS permissions, wrong identity or writes outside the ESO stack."""
import copy
import argparse
import json
from pathlib import Path
import re

STACK = Path(__file__).resolve().parent.parent


def check(plan, gitops_secret_arn=None, review_service_secret_arn=None):
    count = 0

    def require(ok, message):
        nonlocal count
        if not ok:
            raise ValueError(message)
        count += 1

    require(plan['terraform_version'] == '1.5.7', 'Terraform version')
    provider = plan['configuration']['provider_config']['aws']['expressions']
    require(provider['allowed_account_ids']['constant_value'] == ['123456789012'], 'account guard')
    require(plan['variables']['aws_region']['value'] == 'ap-northeast-2', 'region')
    require(plan['variables'].get('gitops_token_secret_arn', {}).get('value') == gitops_secret_arn, 'expected GitOps Secret input')
    if gitops_secret_arn is not None:
        require(re.fullmatch(r'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}', gitops_secret_arn) is not None, 'GitOps full Secret ARN')
    require(plan['variables'].get('review_service_secret_arn', {}).get('value') == review_service_secret_arn, 'expected review-service Secret input')
    if review_service_secret_arn is not None:
        require(re.fullmatch(r'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-[A-Za-z0-9]{6}', review_service_secret_arn) is not None, 'review-service full Secret ARN')
    resources = {r['address']: r for r in plan['resource_changes'] if r['mode'] == 'managed'}
    expected_resources = {'aws_iam_role.eso', 'aws_iam_role_policy.read_rds', 'aws_eks_pod_identity_association.eso'}
    if gitops_secret_arn is not None:
        expected_resources.add('aws_iam_role_policy.read_gitops[0]')
    if review_service_secret_arn is not None:
        expected_resources.add('aws_iam_role_policy.read_review_service[0]')
    require(set(resources) == expected_resources, 'resource scope')
    for r in resources.values():
        require(r['change']['actions'] in [['create'], ['no-op']], 'update/delete/replace')
        if review_service_secret_arn is not None and r['address'] != 'aws_iam_role_policy.read_review_service[0]':
            require(r['change']['actions'] == ['no-op'], 'existing ESO and GitOps resources unchanged')
        elif review_service_secret_arn is None and gitops_secret_arn is not None and r['address'] != 'aws_iam_role_policy.read_gitops[0]':
            require(r['change']['actions'] == ['no-op'], 'existing ESO resources unchanged')
        tags = r['change']['after'].get('tags_all')
        if tags:
            require(tags == {'Project': 'oneaction', 'Env': 'dev', 'Owner': 'hyeyeon.kim'}, 'tags')
    prior = {r['address']: r['values'] for r in plan['prior_state']['values']['root_module']['resources']}
    for name in ['eks', 'database']:
        state = prior[f'data.terraform_remote_state.{name}']['config']
        require(state['key'] == f'dev/{name}/terraform.tfstate', 'state key')
        require(state['bucket'] == 'oneaction-tfstate-123456789012' and state['region'] == 'ap-northeast-2', 'state account and region')
        require(state['encrypt'] is True and state['dynamodb_table'] == 'oneaction-terraform-locks', 'state encryption and lock')
    cluster_arn = prior['data.terraform_remote_state.eks']['outputs']['cluster_arn']
    secret_arn = prior['data.terraform_remote_state.database']['outputs']['db_master_user_secret_arn']
    require(cluster_arn == 'arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction', 'cluster ARN')
    require(secret_arn.startswith('arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-'), 'RDS Secret ARN')
    require(prior['data.aws_secretsmanager_secret.rds']['arn'] == secret_arn, 'Secret metadata matches database state')
    require(not prior['data.aws_secretsmanager_secret.rds'].get('kms_key_id'), 'unexpected customer-managed KMS key')
    role = resources['aws_iam_role.eso']['change']['after']
    require(role['name'] == 'oneaction-external-secrets', 'role name')
    trust = json.loads(role['assume_role_policy'])['Statement']
    require(len(trust) == 1 and trust[0]['Effect'] == 'Allow', 'trust statements')
    require(trust[0]['Principal'] == {'Service': 'pods.eks.amazonaws.com'}, 'Pod Identity principal')
    require(set(trust[0]['Action']) == {'sts:AssumeRole', 'sts:TagSession'}, 'trust actions')
    require(trust[0]['Condition'] == {'StringEquals': {
        'aws:RequestTag/eks-cluster-arn': cluster_arn,
        'aws:RequestTag/kubernetes-namespace': 'external-secrets',
        'aws:RequestTag/kubernetes-service-account': 'external-secrets',
    }}, 'exact cluster, namespace and ServiceAccount trust')
    inline = resources['aws_iam_role_policy.read_rds']['change']['after']
    require(inline['role'] == role['name'] and inline['name'] == 'read-review-db-secret', 'policy identity')
    require(len(inline['policy']) <= 10240, 'inline quota')
    policy = json.loads(inline['policy'])
    require(policy['Version'] == '2012-10-17' and len(policy['Statement']) == 1, 'policy statements')
    s = policy['Statement'][0]
    require(s['Effect'] == 'Allow', 'policy effect')
    require(set(s['Action']) == {'secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'}, 'read-only actions')
    require(s['Resource'] == secret_arn, 'single exact Secret boundary')
    require(s['Condition'] == {'StringEquals': {'aws:RequestedRegion': 'ap-northeast-2'}}, 'API region boundary')
    if gitops_secret_arn is not None:
        require(gitops_secret_arn != secret_arn, 'GitOps and RDS Secrets are separate')
        # Terraform 1.5.7 records data read during planning in the refreshed prior state.
        gitops_metadata = prior.get('data.aws_secretsmanager_secret.gitops[0]', {})
        require(gitops_metadata.get('arn') == gitops_secret_arn, 'GitOps Secret metadata matches input')
        require(not gitops_metadata.get('kms_key_id'), 'explicit GitOps KMS key requires review')
        gitops = resources['aws_iam_role_policy.read_gitops[0]']['change']['after']
        require(gitops['role'] == role['name'] and gitops['name'] == 'read-gitops-token-secret', 'GitOps policy identity')
        require(len(gitops['policy']) <= 10240, 'GitOps inline quota')
        gitops_policy = json.loads(gitops['policy'])
        require(gitops_policy['Version'] == '2012-10-17' and len(gitops_policy['Statement']) == 1, 'GitOps policy statements')
        gs = gitops_policy['Statement'][0]
        require(gs['Effect'] == 'Allow', 'GitOps policy effect')
        require(set(gs['Action']) == {'secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'}, 'GitOps read-only actions')
        require(gs['Resource'] == gitops_secret_arn, 'single exact GitOps Secret boundary')
        require(gs['Condition'] == {'StringEquals': {'aws:RequestedRegion': 'ap-northeast-2'}}, 'GitOps API region boundary')
        require(plan['planned_values']['outputs']['gitops_token_secret_arn']['value'] == gitops_secret_arn, 'GitOps ARN output')
        require(all(change['actions'] == ['no-op'] for name, change in plan.get('output_changes', {}).items() if name not in {'gitops_token_secret_arn', 'review_service_secret_arn'}), 'existing ESO outputs unchanged')
    if review_service_secret_arn is not None:
        require(review_service_secret_arn not in {secret_arn, gitops_secret_arn}, 'review-service Secret is separate')
        metadata = prior.get('data.aws_secretsmanager_secret.review_service[0]', {})
        require(metadata.get('arn') == review_service_secret_arn and metadata.get('name') == 'oneaction/review-service', 'review-service Secret metadata matches input')
        require(not metadata.get('kms_key_id'), 'explicit review-service KMS key requires review')
        review = resources['aws_iam_role_policy.read_review_service[0]']['change']['after']
        require(review['role'] == role['name'] and review['name'] == 'read-review-service-secret', 'review-service policy identity')
        document = json.loads(review['policy'])
        require(document['Version'] == '2012-10-17' and len(document['Statement']) == 1, 'review-service policy statements')
        rs = document['Statement'][0]
        require(rs == {
            'Effect': 'Allow',
            'Action': ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'],
            'Resource': review_service_secret_arn,
            'Condition': {'StringEquals': {'aws:RequestedRegion': 'ap-northeast-2'}},
        }, 'exact read-only review-service policy')
        require(plan['planned_values']['outputs']['review_service_secret_arn']['value'] == review_service_secret_arn, 'review-service ARN output')
        require(all(change['actions'] == ['no-op'] for name, change in plan.get('output_changes', {}).items() if name != 'review_service_secret_arn'), 'existing ESO outputs unchanged for review-service addition')
    require(sum(len(r['change']['after']['policy']) for r in resources.values() if r['type'] == 'aws_iam_role_policy') <= 10240, 'aggregate inline policy quota')
    association = resources['aws_eks_pod_identity_association.eso']['change']['after']
    require(association['cluster_name'] == 'oneaction' and association['namespace'] == 'external-secrets' and association['service_account'] == 'external-secrets', 'association identity')
    configuration = {r['address']: r for r in plan['configuration']['root_module']['resources']}
    require('aws_iam_role.eso.arn' in configuration['aws_eks_pod_identity_association.eso']['expressions']['role_arn']['references'], 'association role reference')
    require('aws_iam_role_policy.read_rds' in configuration['aws_eks_pod_identity_association.eso']['depends_on'], 'policy ready before association')
    require(not any('secret_version' in r['type'] or 'kubernetes' in r['type'] for r in plan['resource_changes']), 'no payload in Terraform')
    require(plan['planned_values']['outputs']['target_namespace']['value'] == 'platform', 'target namespace')
    require('dev/eks-eso/terraform.tfstate' in (STACK / 'versions.tf').read_text(), 'own backend key')
    return count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--gitops-token-secret-arn', help='Expected exact ARN, required when enabling the GitOps policy.')
    parser.add_argument('--review-service-secret-arn', help='Expected exact ARN, required when enabling the Claude Secret policy.')
    parser.add_argument('--negative', action='store_true')
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text(encoding='utf-8-sig'))
    print(f'PASS: {check(plan, args.gitops_token_secret_arn, args.review_service_secret_arn)} ESO plan safety checks.')
    if args.negative:
        def mutate_policy(p, mode):
            r = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.read_rds')
            policy = json.loads(r['change']['after']['policy'])
            if mode == 'write':
                policy['Statement'][0]['Action'].append('secretsmanager:PutSecretValue')
            else:
                policy['Statement'][0]['Resource'] = '*'
            r['change']['after']['policy'] = json.dumps(policy)

        def mutate_trust(p):
            r = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.eso')
            trust = json.loads(r['change']['after']['assume_role_policy'])
            trust['Statement'][0]['Condition']['StringEquals']['aws:RequestTag/kubernetes-service-account'] = '*'
            r['change']['after']['assume_role_policy'] = json.dumps(trust)

        cases = {
            'wrong account': lambda p: p['configuration']['provider_config']['aws']['expressions']['allowed_account_ids'].update(constant_value=['111122223333']),
            'role deletion': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.eso')['change'].update(actions=['delete']),
            'other ServiceAccounts': mutate_trust,
            'Secret writes': lambda p: mutate_policy(p, 'write'),
            'all Secret reads': lambda p: mutate_policy(p, 'scope'),
            'wrong association namespace': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_eks_pod_identity_association.eso')['change']['after'].update(namespace='default'),
        }
        if args.review_service_secret_arn is not None:
            def review_policy(p, field, value):
                r = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.read_review_service[0]')
                document = json.loads(r['change']['after']['policy'])
                document['Statement'][0][field] = value
                r['change']['after']['policy'] = json.dumps(document)

            def review_metadata(p, field, value):
                next(r for r in p['prior_state']['values']['root_module']['resources'] if r['address'] == 'data.aws_secretsmanager_secret.review_service[0]')['values'][field] = value

            def resource_change(p, address, field, value):
                next(r for r in p['resource_changes'] if r['address'] == address)['change']['after'][field] = value

            cases.update({
                'Claude Secret writes': lambda p: review_policy(p, 'Action', ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret', 'secretsmanager:PutSecretValue']),
                'wildcard Claude Secret': lambda p: review_policy(p, 'Resource', '*'),
                'multiple Claude Secrets': lambda p: review_policy(p, 'Resource', [args.review_service_secret_arn, args.gitops_token_secret_arn]),
                'Claude region removal': lambda p: review_policy(p, 'Condition', {}),
                'other Claude role': lambda p: resource_change(p, 'aws_iam_role_policy.read_review_service[0]', 'role', 'other-role'),
                'unreviewed Claude KMS key': lambda p: review_metadata(p, 'kms_key_id', 'arn:aws:kms:ap-northeast-2:123456789012:key/unreviewed'),
                'other Claude Secret metadata': lambda p: review_metadata(p, 'arn', args.review_service_secret_arn + 'other'),
                'other Claude Secret name': lambda p: review_metadata(p, 'name', 'other-secret'),
                'Claude policy replacement': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.read_review_service[0]')['change'].update(actions=['delete', 'create']),
                'other account Claude ARN': lambda p: p['variables']['review_service_secret_arn'].update(value=args.review_service_secret_arn.replace('123456789012', '111122223333')),
                'other region Claude ARN': lambda p: p['variables']['review_service_secret_arn'].update(value=args.review_service_secret_arn.replace('ap-northeast-2', 'us-east-1')),
            })
            if args.gitops_token_secret_arn is not None:
                cases.update({
                    'GitOps policy update': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.read_gitops[0]')['change'].update(actions=['update']),
                    'existing GitOps output update': lambda p: p['output_changes']['gitops_token_secret_arn'].update(actions=['update']),
                })
        for name, mutate in cases.items():
            bad = copy.deepcopy(plan)
            mutate(bad)
            try:
                check(bad, args.gitops_token_secret_arn, args.review_service_secret_arn)
            except ValueError:
                print(f'PASS (rejected): {name}')
            else:
                raise AssertionError(f'Unsafe plan accepted: {name}')
