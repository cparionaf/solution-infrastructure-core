variable "enable_nat_gateway" {
  type = bool
  default = true
}

variable "single_nat_gateway" {
  type = bool
  default = true
}

variable "private_subnets_cidr_block" {
  type = list(string)
  default =  ["10.0.16.0/20", "10.0.32.0/20"]
}

variable "public_subnets_cidr_block" {
  type = list(string)  
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "vpc_cidr" {
  type = string
  default = "10.0.0.0/16"
}
variable "project_name" {
  type = string
  default = "solutions-architecture-moc"
}

variable "environment" {
  type = string
  default = "dev"
}

variable "aws_region" {
  type = string
  default = "us-east-1"
}

variable "karpenter_version" {
  type = string
  default = "1.0.8"
}

variable "cluster_version" {
  type = string
  default = "1.31"
}

variable "managed_node_group_name" {
  type = string
  default = "moc-mng"
}

variable "cluster_name" {
  type = string
  default = "solutions-architecture-moc"
}

variable "domain_name" {
  type = string
  default = "poc-architecture.carlospariona.dev"
}

variable "notification_email" {
  type = string
  default = "info@carlospariona.dev"
}

variable "mng_config" {
  type = object({
    instance_types = list(string)
    min_size = number
    max_size = number
    desired_size = number
  })

  default = {
    instance_types = ["t3.medium"]
    min_size = 2
    max_size = 2
    desired_size = 2
  }
}