"""Accept only an additive public API /32 allowlist update for oneaction."""
import argparse
import copy
import ipaddress
import json
from pathlib import Path


def validate(plan, expected_cidrs):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    expected = set(expected_cidrs)
    require(bool(expected), 'Supply the entire reviewed allowlist.')
    for cidr in expected:
        network = ipaddress.ip_network(cidr, strict=True)
        require(network.version == 4 and network.prefixlen == 32, 'Use individual IPv4 /32 entries.')
    require(plan['terraform_version'] == '1.5.7', 'Use reviewed Terraform 1.5.7.')
    provider = plan['configuration']['provider_config']['aws']['expressions']
    require(provider['allowed_account_ids']['constant_value'] == ['123456789012'], 'Unexpected AWS account guard.')
    require(plan['variables']['aws_region']['value'] == 'ap-northeast-2', 'Unexpected workload region.')
    changed = [r for r in plan['resource_changes'] if r['mode'] == 'managed' and r['change']['actions'] != ['no-op']]
    require(len(changed) == 1 and changed[0]['address'] == 'aws_eks_cluster.this', 'Only the EKS cluster may change.')
    change = changed[0]['change']
    require(change['actions'] == ['update'], 'Creation, deletion or replacement is not allowed.')
    before, after = change['before'], change['after']
    require(before['arn'] == 'arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction', 'Unexpected cluster ARN.')
    require(len(before['vpc_config']) == len(after['vpc_config']) == 1, 'Unexpected VPC configuration.')
    prior = set(before['vpc_config'][0]['public_access_cidrs'])
    target = set(after['vpc_config'][0]['public_access_cidrs'])
    require(target == expected, 'The plan does not match the entire reviewed allowlist.')
    require(prior < target, 'Retain every existing CIDR and add at least one new entry.')
    require(after['vpc_config'][0]['endpoint_private_access'] is True, 'Private endpoint must remain enabled.')
    require(after['vpc_config'][0]['endpoint_public_access'] is True, 'Public endpoint must remain enabled.')
    normalized = copy.deepcopy(after)
    normalized['vpc_config'][0]['public_access_cidrs'] = before['vpc_config'][0]['public_access_cidrs']
    require(before == normalized, 'Another cluster field changes alongside the allowlist.')
    require(all(c['actions'] == ['no-op'] for c in plan.get('output_changes', {}).values()), 'Root outputs must remain unchanged.')
    return sorted(prior), sorted(target - prior)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--cidr', action='append', required=True, help='Repeat for every CIDR in the complete desired allowlist.')
    arguments = parser.parse_args()
    reviewed_plan = json.loads(arguments.plan.read_text(encoding='utf-8-sig'))
    retained, added = validate(reviewed_plan, arguments.cidr)
    print('PASS: 0 create, 1 in-place update, 0 delete; only public API CIDRs change.')
    print('RETAIN: ' + ', '.join(retained))
    print('ADD: ' + ', '.join(added))
    print('PASS: both endpoints and every other cluster field, managed resource and root output remain unchanged.')
