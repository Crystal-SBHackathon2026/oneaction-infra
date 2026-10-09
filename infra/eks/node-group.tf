resource "aws_launch_template" "node" {
  name_prefix = "${local.cluster_name}-eks-node-"

  # Provider 5.100 sends credit_specification only with an explicit burstable type.
  instance_type = var.node_instance_types[0]

  # EKS does not automatically attach its cluster SG when a custom SG is set.
  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    data.terraform_remote_state.network.outputs.eks_node_extra_security_group_id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.node_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.node_tags
  }

  tags = { Name = "${local.cluster_name}-eks-node" }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.cluster_name}-general"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.terraform_remote_state.network.outputs.private_eks_subnet_ids
  version         = var.cluster_version
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  # Explicitly clear node-group types; the launch template owns the single type.
  instance_types = []

  launch_template {
    id      = aws_launch_template.node.id
    version = tostring(aws_launch_template.node.latest_version)
  }

  scaling_config {
    min_size     = var.node_scaling.min
    desired_size = var.node_scaling.desired
    max_size     = var.node_scaling.max
  }

  update_config {
    max_unavailable = 1
  }

  tags = { Name = "${local.cluster_name}-general" }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.networking,
  ]
}
