# external secrets CDRS
resource "kubectl_manifest" "secret_store" {
    yaml_body = <<YAML
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secret-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${var.aws_region}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: kube-system
YAML

depends_on = [ module.eks, helm_release.external_secrets]
}

### Karpenter CDRs
# NodePool usando kubectl_manifest
resource "kubectl_manifest" "nodepool" {
    yaml_body = <<YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
  limits:
    cpu: "1000"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
YAML
  depends_on = [module.eks, module.aws_auth, helm_release.karpenter]
}

# EC2NodeClass usando kubectl_manifest
resource "kubectl_manifest" "ec2nodeclass" {
    yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: ${module.karpenter.node_iam_role_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  amiSelectorTerms:
    - alias: al2@latest
YAML
  depends_on = [module.eks, module.aws_auth, helm_release.karpenter]
}

resource "kubectl_manifest" "cluster_issuer_prod" {
    yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: kube-system
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.notification_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - dns01:
        route53: {}
      selector:
        dnsZones:
          - "${var.domain_name}"  
          - "*.${var.domain_name}"  
YAML
    depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "monitoring_ingress" {
    yaml_body = <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/healthcheck-path: /login
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    

    # alb.ingress.kubernetes.io/cors-allow-origins: 'https://*.${var.domain_name}'
    # alb.ingress.kubernetes.io/cors-allow-methods: 'GET, POST, OPTIONS'
    # alb.ingress.kubernetes.io/cors-allow-headers: 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Authorization'
    # alb.ingress.kubernetes.io/cors-max-age: '86400'

    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    # External Dns
    external-dns.alpha.kubernetes.io/owner-id: "cluster-${var.aws_region}"
    external-dns.alpha.kubernetes.io/hostname: "*.${var.domain_name}"
    external-dns.alpha.kubernetes.io/ttl: "60"

spec:
  ingressClassName: alb
  tls: 
  - hosts: 
    - "*.${var.domain_name}"
    secretName: region-dns-wildcard-tls
    
  rules:
  - host: grafana-${var.aws_region}.${var.domain_name}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-stack-grafana
            port:
              number: 80

  # - host: prometheus-${var.aws_region}.${var.domain_name}
  #   http:
  #     paths:
  #     - path: /
  #       pathType: Prefix
  #       backend:
  #         service:
  #           name: prometheus-stack-kube-prom-prometheus
  #           port:
  #             number: 9090 

  # - host: alertmanager-${var.aws_region}.${var.domain_name}
  #   http:
  #     paths:
  #     - path: /
  #       pathType: Prefix
  #       backend:
  #         service:
  #           name: prometheus-stack-kube-prom-alertmanager
  #           port:
  #             number: 9093
YAML
    depends_on = [ helm_release.kube_prometheus_stack ]
}