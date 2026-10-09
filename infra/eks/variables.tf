variable "aws_profile" {
  description = "AWS CLI profile, or empty when using exported temporary credentials."
  type        = string
  default     = ""
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "The oneaction handoff requires the Seoul Region ap-northeast-2."
  }
}

variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}

variable "cluster_version" {
  description = "Explicit EKS Kubernetes version; verify standard support before applying."
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "Use a Kubernetes minor version such as 1.36."
  }
}

variable "public_access_cidrs" {
  description = "Approved IPv4 egress CIDRs for operators and external Argo CD. No world-open API access."
  type        = set(string)

  validation {
    condition = length(var.public_access_cidrs) > 0 && alltrue([
      for cidr in var.public_access_cidrs :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 24, false)
    ])
    error_message = "Supply at least one explicit IPv4 CIDR with /24 or narrower; prefer each operator's /32."
  }
}

variable "admin_principal_arns" {
  description = "Stable IAM role ARNs approved for cluster administration, not STS session ARNs."
  type        = set(string)

  validation {
    condition = length(var.admin_principal_arns) > 0 && alltrue([
      for arn in var.admin_principal_arns :
      can(regex("^arn:aws:iam::123456789012:role/.+$", arn))
    ])
    error_message = "Supply existing IAM role ARNs in team account 123456789012. STS assumed-role and root ARNs are not accepted."
  }
}

variable "node_instance_types" {
  description = "One T3/T3a x86_64 instance type set in the launch template so standard CPU credits reach AWS."
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition = length(var.node_instance_types) == 1 && alltrue([
      for instance_type in var.node_instance_types : can(regex("^t3a?\\.(medium|large|xlarge|2xlarge)$", instance_type))
    ])
    error_message = "Use T3 or T3a x86_64 instances, medium or larger, compatible with the launch template CPU-credit setting. Supply exactly one instance type."
  }
}

variable "node_scaling" {
  description = "Initial desired size and explicit minimum/maximum bounds. No autoscaler is installed."
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = {
    min     = 3
    desired = 3
    max     = 3
  }

  validation {
    condition = (
      var.node_scaling.min >= 1 &&
      var.node_scaling.min <= var.node_scaling.desired &&
      var.node_scaling.desired <= var.node_scaling.max &&
      alltrue([for count in values(var.node_scaling) : count == floor(count)])
    )
    error_message = "Node counts must be integers and satisfy 1 <= min <= desired <= max."
  }
}

variable "addon_versions" {
  description = "Reviewed version pins for Kubernetes 1.36. Review these together with cluster_version before an upgrade."
  type        = map(string)
  default = {
    vpc-cni                = "v1.22.4-eksbuild.3"
    kube-proxy             = "v1.36.0-eksbuild.25"
    coredns                = "v1.14.6-eksbuild.4"
    eks-pod-identity-agent = "v1.3.10-eksbuild.3"
  }

  validation {
    condition = length(var.addon_versions) == 4 && alltrue([
      for name in keys(var.addon_versions) :
      contains(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"], name)
      ]) && alltrue([
      for version in values(var.addon_versions) : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", version))
    ])
    error_message = "Pin all four foundation add-ons to explicit EKS build versions."
  }
}
