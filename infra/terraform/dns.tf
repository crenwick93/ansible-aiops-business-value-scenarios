# DNS records and Elastic IPs
#
# Elastic IPs survive instance stop/start, so domain names remain stable
# when the demo environment shuts down overnight and boots back up.
# Private-subnet instances (Kafka, Postgres) keep their private IPs across
# restarts within a VPC, so no EIPs needed for those.

locals {
  dns_enabled = var.domain_name != ""
  zone_id     = local.dns_enabled ? (var.route53_zone_id != "" ? var.route53_zone_id : data.aws_route53_zone.demo[0].zone_id) : ""
}

# Look up the hosted zone by name if zone_id wasn't provided explicitly
data "aws_route53_zone" "demo" {
  count = local.dns_enabled && var.route53_zone_id == "" ? 1 : 0
  name  = "${var.domain_name}."
}

# ---------------------------------------------------------------------------
# Elastic IPs for public-facing instances (survive stop/start)
# ---------------------------------------------------------------------------

resource "aws_eip" "payment_svc" {
  count  = local.dns_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.project_tag}-payment-svc-eip" })
}

resource "aws_eip_association" "payment_svc" {
  count         = local.dns_enabled ? 1 : 0
  instance_id   = aws_instance.payment_svc.id
  allocation_id = aws_eip.payment_svc[0].id
}

resource "aws_eip" "app_svc" {
  count  = local.dns_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.project_tag}-app-svc-eip" })
}

resource "aws_eip_association" "app_svc" {
  count         = local.dns_enabled ? 1 : 0
  instance_id   = aws_instance.app_svc.id
  allocation_id = aws_eip.app_svc[0].id
}

resource "aws_eip" "dashboard" {
  count  = local.dns_enabled ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.project_tag}-dashboard-eip" })
}

resource "aws_eip_association" "dashboard" {
  count         = local.dns_enabled ? 1 : 0
  instance_id   = aws_instance.dashboard.id
  allocation_id = aws_eip.dashboard[0].id
}

# ---------------------------------------------------------------------------
# Route53 DNS records
# ---------------------------------------------------------------------------

# Public-facing services — point to Elastic IPs
resource "aws_route53_record" "payment_svc" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "payment-svc.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.payment_svc[0].public_ip]
}

resource "aws_route53_record" "app_svc" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "app-svc.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app_svc[0].public_ip]
}

resource "aws_route53_record" "dashboard" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "dashboard.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.dashboard[0].public_ip]
}

resource "aws_route53_record" "customer_view" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "customer-view.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.dashboard[0].public_ip]
}

resource "aws_route53_record" "ops_view" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "ops-view.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.dashboard[0].public_ip]
}

# Internal services — private IPs (stable within VPC across restarts)
resource "aws_route53_record" "kafka" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "kafka.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.kafka.private_ip]
}

resource "aws_route53_record" "postgres" {
  count   = local.dns_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = "postgres.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.postgres.private_ip]
}
