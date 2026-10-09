# Copy to local.auto.tfvars (ignored by Git) and replace both examples.
public_access_cidrs = ["203.0.113.10/32"]
admin_principal_arns = [
  "arn:aws:iam::123456789012:role/REPLACE_WITH_APPROVED_IAM_ROLE_PATH",
]

# Retain the same Owner convention as existing stacks, or set the agreed owner.
owner = "hyeyeon.kim"

cluster_version     = "1.36"
node_instance_types = ["t3.medium"]
node_scaling = {
  min     = 3
  desired = 3
  max     = 3
}
