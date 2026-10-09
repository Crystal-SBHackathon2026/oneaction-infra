"""Verify a Notifications-only addition or a post-apply no-op ESO plan.

Only Terraform plan metadata is read. No Secret payload or AWS call is needed.
Existing ESO resources must be no-op; the new role, inline policy and Pod Identity
association must either all be created or all remain unchanged.
"""
import argparse
import copy
import json
from pathlib import Path
import re

from check_plan import check as check_existing_eso


REVIEW_SECRET = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-GhIjKl"
GITOPS_SECRET = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/gitops-token-AbCdEf"
CLUSTER_ARN = "arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction"
ROLE_NAME = "oneaction-external-secrets-argocd"
ROLE_ARN = f"arn:aws:iam::123456789012:role/{ROLE_NAME}"
OPERATOR_NAMESPACE = "external-secrets"
SERVICE_ACCOUNT = "external-secrets-argocd"
TARGET_NAMESPACE = "argocd"
ROLE = "aws_iam_role.notifications[0]"
POLICY = "aws_iam_role_policy.read_notifications[0]"
ASSOCIATION = "aws_eks_pod_identity_association.notifications[0]"
NEW_RESOURCES = {ROLE, POLICY, ASSOCIATION}
NEW_OUTPUTS = {
    "notifications_role_arn", "notifications_association_id",
    "notifications_operator_namespace", "notifications_service_account",
    "notifications_target_namespace",
}


def check(plan, review_service_secret_arn=REVIEW_SECRET, gitops_token_secret_arn=GITOPS_SECRET, phase="create"):
    """Reject an unexpected write or a widened Kubernetes/AWS identity boundary."""
    count = 0

    def require(ok, message):
        nonlocal count
        if not ok:
            raise ValueError(message)
        count += 1

    require(phase in {"create", "steady"}, "known deployment phase")
    require(isinstance(review_service_secret_arn, str) and re.fullmatch(
        r"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-[A-Za-z0-9]{6}",
        review_service_secret_arn,
    ) is not None, "one exact review-service Secret ARN")
    changes = plan.get("resource_changes", [])
    resources = {r["address"]: r for r in changes if r["mode"] == "managed"}
    require(NEW_RESOURCES <= set(resources), "all three Notifications resources present")
    action = ["create"] if phase == "create" else ["no-op"]
    for address in NEW_RESOURCES:
        require(resources[address]["change"]["actions"] == action, f"Notifications {phase} resource actions")
    for address, resource in resources.items():
        if address not in NEW_RESOURCES:
            require(resource["change"]["actions"] == ["no-op"], "existing ESO resources unchanged")
    require(all(change["actions"] == ["no-op"] for name, change in plan.get("output_changes", {}).items()
                if name not in NEW_OUTPUTS), "existing ESO outputs unchanged")
    # Reuse the existing scope, account, region, metadata and permission checks.
    # New resources and their outputs are removed only from this validation copy.
    existing = copy.deepcopy(plan)
    existing["resource_changes"] = [r for r in changes if r["address"] not in NEW_RESOURCES]
    for name in NEW_OUTPUTS:
        existing.get("output_changes", {}).pop(name, None)
        existing["planned_values"]["outputs"].pop(name, None)
    count += check_existing_eso(existing, gitops_token_secret_arn, review_service_secret_arn)

    for address in NEW_RESOURCES:
        tags = resources[address]["change"]["after"].get("tags_all")
        if tags is not None:
            require(tags == {"Project": "oneaction", "Env": "dev", "Owner": "hyeyeon.kim"}, "Notifications tags")
    role = resources[ROLE]["change"]["after"]
    require(role["name"] == ROLE_NAME, "Notifications role name")
    if phase == "steady":
        require(role["arn"] == ROLE_ARN, "Notifications role ARN")
    trust = json.loads(role["assume_role_policy"])
    require(trust.get("Version") == "2012-10-17" and len(trust.get("Statement", [])) == 1, "one trust statement")
    statement = trust["Statement"][0]
    require(set(statement) <= {"Effect", "Action", "Principal", "Condition", "Sid"}, "no alternative trust permissions")
    require(statement.get("Sid", "") == "", "unmodified trust statement identity")
    require(statement["Effect"] == "Allow", "trust effect")
    require(statement["Principal"] == {"Service": "pods.eks.amazonaws.com"}, "Pod Identity trust principal")
    require(set(statement["Action"]) == {"sts:AssumeRole", "sts:TagSession"}, "Pod Identity trust actions")
    require(statement["Condition"] == {"StringEquals": {
        "aws:RequestTag/eks-cluster-arn": CLUSTER_ARN,
        "aws:RequestTag/kubernetes-namespace": OPERATOR_NAMESPACE,
        "aws:RequestTag/kubernetes-service-account": SERVICE_ACCOUNT,
    }}, "exact Notifications cluster, namespace and ServiceAccount trust")

    inline = resources[POLICY]["change"]["after"]
    require(inline["name"] == "read-argocd-notifications-secret" and inline["role"] == ROLE_NAME, "Notifications policy identity")
    require(len(inline["policy"]) <= 10240, "Notifications inline policy quota")
    require(json.loads(inline["policy"]) == {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
            "Resource": review_service_secret_arn,
            "Condition": {"StringEquals": {"aws:RequestedRegion": "ap-northeast-2"}},
        }],
    }, "exact region-restricted review-service read policy")
    association = resources[ASSOCIATION]["change"]["after"]
    require(association["cluster_name"] == "oneaction" and
            association["namespace"] == OPERATOR_NAMESPACE and
            association["service_account"] == SERVICE_ACCOUNT, "Notifications association identity")
    require(association.get("disable_session_tags") is not True, "Pod Identity session tags enabled")
    require(association.get("target_role_arn") in {None, ""}, "no chained Pod Identity role")
    if phase == "steady":
        require(association["role_arn"] == ROLE_ARN, "Notifications association role ARN")

    configuration = {r["address"]: r for r in plan["configuration"]["root_module"]["resources"]}
    role_config = configuration["aws_iam_role.notifications"]
    association_config = configuration["aws_eks_pod_identity_association.notifications"]
    policy_config = configuration["aws_iam_role_policy.read_notifications"]
    require(not {"managed_policy_arns", "inline_policy"} & set(role_config["expressions"]), "no extra role policies")
    require("aws_iam_role.notifications[0].name" in policy_config["expressions"]["role"]["references"], "inline policy bound to Notifications role")
    require("aws_iam_role.notifications[0].arn" in association_config["expressions"]["role_arn"]["references"], "association bound to Notifications role")
    require("aws_iam_role_policy.read_notifications" in association_config.get("depends_on", []), "policy ready before association")
    output_values = plan["planned_values"]["outputs"]
    for name, value in {
        "notifications_operator_namespace": OPERATOR_NAMESPACE,
        "notifications_service_account": SERVICE_ACCOUNT,
        "notifications_target_namespace": TARGET_NAMESPACE,
    }.items():
        require(output_values.get(name, {}).get("value") == value, "Notifications output identity")
    if phase == "steady":
        require(output_values.get("notifications_role_arn", {}).get("value") == ROLE_ARN, "Notifications role output")
        require(isinstance(output_values.get("notifications_association_id", {}).get("value"), str) and
                bool(output_values["notifications_association_id"]["value"]), "Notifications association output")
        require(all(change["actions"] == ["no-op"] for change in plan.get("output_changes", {}).values()), "all post-apply outputs unchanged")
    else:
        require(set(plan.get("output_changes", {})) >= NEW_OUTPUTS, "new Notifications outputs present")
        require(all(plan["output_changes"][name]["actions"] == ["create"] for name in NEW_OUTPUTS), "only new Notifications outputs created")
    return count


def check_negative_cases(plan, review_service_secret_arn, gitops_token_secret_arn, phase):
    """Mutate a real plan copy to verify the guard rejects relevant unsafe changes."""
    def resource(p, address):
        return next(r for r in p["resource_changes"] if r["address"] == address)

    def mutate_policy(p, field, value):
        document = json.loads(resource(p, POLICY)["change"]["after"]["policy"])
        document["Statement"][0][field] = value
        resource(p, POLICY)["change"]["after"]["policy"] = json.dumps(document)

    def mutate_trust(p, tag, value):
        document = json.loads(resource(p, ROLE)["change"]["after"]["assume_role_policy"])
        document["Statement"][0]["Condition"]["StringEquals"][tag] = value
        resource(p, ROLE)["change"]["after"]["assume_role_policy"] = json.dumps(document)

    def mutate_config(p, address, expression):
        config = next(r for r in p["configuration"]["root_module"]["resources"] if r["address"] == address)
        config["expressions"][expression] = {"references": ["aws_iam_role.eso.arn"]}

    def mutate_metadata(p):
        metadata = next(r for r in p["prior_state"]["values"]["root_module"]["resources"] if r["address"] == "data.aws_secretsmanager_secret.review_service[0]")
        metadata["values"]["kms_key_id"] = "arn:aws:kms:ap-northeast-2:123456789012:key/unreviewed"

    cases = {
        "wrong AWS account": lambda p: p["configuration"]["provider_config"]["aws"]["expressions"]["allowed_account_ids"].update(constant_value=["111122223333"]),
        "existing platform role update": lambda p: resource(p, "aws_iam_role.eso")["change"].update(actions=["update"]),
        "Notifications role replacement": lambda p: resource(p, ROLE)["change"].update(actions=["delete", "create"]),
        "mixed new resource actions": lambda p: resource(p, POLICY)["change"].update(actions=["no-op"] if phase == "create" else ["create"]),
        "wildcard Secret read": lambda p: mutate_policy(p, "Resource", "*"),
        "Secret write": lambda p: mutate_policy(p, "Action", ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue"]),
        "multiple Secrets": lambda p: mutate_policy(p, "Resource", [review_service_secret_arn, gitops_token_secret_arn]),
        "missing region boundary": lambda p: mutate_policy(p, "Condition", {}),
        "wrong policy role": lambda p: resource(p, POLICY)["change"]["after"].update(role="oneaction-external-secrets"),
        "wildcard ServiceAccount trust": lambda p: mutate_trust(p, "aws:RequestTag/kubernetes-service-account", "*"),
        "wrong namespace trust": lambda p: mutate_trust(p, "aws:RequestTag/kubernetes-namespace", "argocd"),
        "wrong cluster trust": lambda p: mutate_trust(p, "aws:RequestTag/eks-cluster-arn", "*"),
        "wrong association ServiceAccount": lambda p: resource(p, ASSOCIATION)["change"]["after"].update(service_account="external-secrets"),
        "wrong association namespace": lambda p: resource(p, ASSOCIATION)["change"]["after"].update(namespace="argocd"),
        "association bound to platform role": lambda p: mutate_config(p, "aws_eks_pod_identity_association.notifications", "role_arn"),
        "session tags disabled": lambda p: resource(p, ASSOCIATION)["change"]["after"].update(disable_session_tags=True),
        "unreviewed KMS key": mutate_metadata,
        "existing output update": lambda p: p["output_changes"]["target_namespace"].update(actions=["update"]),
        "existing review-service output update": lambda p: p["output_changes"]["review_service_secret_arn"].update(actions=["update"]),
    }
    for name, mutate in cases.items():
        unsafe = copy.deepcopy(plan)
        mutate(unsafe)
        try:
            check(unsafe, review_service_secret_arn, gitops_token_secret_arn, phase)
        except ValueError:
            print(f"PASS (rejected): {name}")
        else:
            raise AssertionError(f"Unsafe plan accepted: {name}")
    return len(cases)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--review-service-secret-arn", default=REVIEW_SECRET, help="Expected full review-service Secret ARN.")
    parser.add_argument("--gitops-token-secret-arn", default=GITOPS_SECRET, help="Expected existing full GitOps Secret ARN.")
    parser.add_argument("--phase", choices=["create", "steady"], default="create")
    parser.add_argument("--negative", action="store_true", help="Exercise rejection cases using copies of this plan.")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text(encoding="utf-8-sig"))
    checks = check(plan, args.review_service_secret_arn, args.gitops_token_secret_arn, args.phase)
    print(f"PASS: {checks} Notifications plan safety checks ({args.phase}).")
    if args.negative:
        checks = check_negative_cases(plan, args.review_service_secret_arn, args.gitops_token_secret_arn, args.phase)
        print(f"PASS: {checks} unsafe plan mutations rejected.")
