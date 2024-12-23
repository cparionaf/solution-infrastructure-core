module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access  = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
    aws-ebs-csi-driver     = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets , module.vpc.public_subnets)

  enable_irsa = true  # Equivalente a withOIDC

  # Tags para Karpenter
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  cluster_security_group_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  # Managed Node Group
  eks_managed_node_groups = {
    
    "${var.managed_node_group_name}" = {
      instance_types = var.mng_config.instance_types
      min_size     = var.mng_config.min_size
      max_size     = var.mng_config.max_size
      desired_size = var.mng_config.desired_size
      subnet_ids   = module.vpc.private_subnets
    }
  }

}

module "aws_auth" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version = "~> 20.0"

  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn  = module.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = [
        "system:bootstrappers",
        "system:nodes"
      ]
    },
    {
      rolearn  = module.eks.eks_managed_node_groups[var.managed_node_group_name].iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = [
        "system:bootstrappers",
        "system:nodes"
      ]
    },    
  ]
  depends_on = [ module.eks, module.karpenter ]
}

# Karpenter Role
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.29.0"
  iam_role_name = "karpenter-${var.environment}"
  cluster_name = var.cluster_name
  create_pod_identity_association = true
  enable_pod_identity = true

  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonEBSCSIDriverPolicy    = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
  depends_on = [ module.eks ]
}

resource "helm_release" "karpenter" {

  namespace        = "kube-system"
  name            = "karpenter"
  repository      = "oci://public.ecr.aws/karpenter"
  chart           = "karpenter"
  version         = var.karpenter_version
  
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 300

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  set {
    name  = "replicas"
    value = "1"
  }

  depends_on = [module.eks, module.karpenter]
}

module "lb_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "eks-alb-controller-role-${var.environment}"
  
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name  
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lb_role.iam_role_arn
  }

  depends_on = [module.eks]

}

resource "helm_release" "metrics_servers" {
  name  = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart= "metrics-server"
  namespace = "kube-system"
  create_namespace = false
  depends_on = [ module.eks ]

}

module "cert_manager_irsa_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                     = "cert-manager-role-${var.environment}"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cert-manager"]
    }
  }
}

resource "helm_release" "cert_manager" {
  name = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart = "cert-manager"
  namespace = "kube-system"
  version = "1.16.2"

  set {
    name = "crds.enabled"
    value = true
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cert_manager_irsa_role.iam_role_arn
  }


  set {
    name  = "prometheus.enabled"
    value = true  
  } 

}

module "external_dns_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "external-dns-role-${var.environment}"
  attach_external_dns_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}

resource "helm_release" "external_dns" {
  name = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart = "external-dns"
  namespace = "kube-system"
  version = "1.15.0"

  set {
    name = "provider"
    value = "aws"
  }

  set {
    name = "policy"
    value = "sync"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_role.iam_role_arn  
  }

  set {
    name = "interval"
    value = "5m"
  }  

  set {
    name  = "events"
    value = "true"
  }

  set {
    name  = "txtOwnerId"
    value = module.eks.cluster_name  
  }  

  depends_on = [ module.eks]
}


resource "helm_release" "external_secrets" {
  name = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart = "external-secrets"
  namespace = "kube-system"
  version = "0.11.0"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_role.iam_role_arn
  }

}

module "external_secrets_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "external-secrets-role-${var.environment}"
  attach_external_secrets_policy = true
  external_secrets_secrets_manager_create_permission  = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-secrets"]
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name = "prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart = "kube-prometheus-stack"
  namespace = "monitoring"
  version = "66.6.0"  
  create_namespace = true
}

