variable "aws_region" {
  description = "AWS region to deploy all resources in."
  type        = string
  default     = "eu-west-1"
}

variable "ssh_key_name" {
  description = "Name of the EC2 key pair in AWS for SSH access to instances."
  type        = string
}

variable "project_tag" {
  description = "Value for the Project tag applied to all resources (also used in Name prefixes)."
  type        = string
  default     = "aiops-demo"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "kafka_instance_type" {
  description = "Instance type for the Apache Kafka (KRaft) broker."
  type        = string
  default     = "t3.medium"
}

variable "postgres_instance_type" {
  description = "Instance type for the PostgreSQL server."
  type        = string
  default     = "t3.small"
}

variable "services_instance_type" {
  description = "Instance type for public-facing app services (payment-svc, app-svc)."
  type        = string
  default     = "t3.small"
}

variable "domain_name" {
  description = "Base domain for service DNS records (e.g. sandbox3331.opentlc.com)."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the domain. If empty and domain_name is set, the zone is looked up by name."
  type        = string
  default     = ""
}
