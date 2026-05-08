output "kafka" {
  description = "Kafka instance addresses"
  value = {
    public_ip  = aws_instance.kafka.public_ip != "" ? aws_instance.kafka.public_ip : "none (private subnet)"
    private_ip = aws_instance.kafka.private_ip
  }
}

output "postgres" {
  description = "PostgreSQL instance addresses"
  value = {
    public_ip  = aws_instance.postgres.public_ip != "" ? aws_instance.postgres.public_ip : "none (private subnet)"
    private_ip = aws_instance.postgres.private_ip
  }
}

output "payment_svc" {
  description = "Payment service (public) instance addresses"
  value = {
    public_ip  = coalesce(aws_instance.payment_svc.public_ip, aws_instance.payment_svc.private_ip)
    private_ip = aws_instance.payment_svc.private_ip
  }
}

output "app_svc" {
  description = "App/consumer service (public) instance addresses"
  value = {
    public_ip  = coalesce(aws_instance.app_svc.public_ip, aws_instance.app_svc.private_ip)
    private_ip = aws_instance.app_svc.private_ip
  }
}

output "kafka_private_ip" {
  description = "Private IP of the Kafka broker (KRaft) for clients"
  value       = aws_instance.kafka.private_ip
}

output "postgres_private_ip" {
  description = "Private IP of the PostgreSQL server for DATABASE_URL and pg_hba"
  value       = aws_instance.postgres.private_ip
}

output "payment_svc_public_ip" {
  description = "Public IP of the payment-svc instance"
  value       = aws_instance.payment_svc.public_ip
}

output "app_svc_public_ip" {
  description = "Public IP of the app-svc instance"
  value       = aws_instance.app_svc.public_ip
}

output "dashboard_public_ip" {
  description = "Public IP of the dashboard instance"
  value       = aws_instance.dashboard.public_ip
}

output "dashboard" {
  description = "Dashboard instance addresses"
  value = {
    public_ip  = aws_instance.dashboard.public_ip
    private_ip = aws_instance.dashboard.private_ip
  }
}

output "dashboard_urls" {
  description = "Dashboard URLs for the demo"
  value = {
    customer_view = local.dns_enabled ? "http://customer-view.${var.domain_name}:8080/" : "http://${aws_instance.dashboard.public_ip}:8080/"
    ops_view      = local.dns_enabled ? "http://ops-view.${var.domain_name}:8080/engineering" : "http://${aws_instance.dashboard.public_ip}:8080/engineering"
  }
}

output "service_urls" {
  description = "Service URLs (domain-based when DNS is configured)"
  value = {
    payment_svc = local.dns_enabled ? "http://payment-svc.${var.domain_name}:5000" : "http://${aws_instance.payment_svc.public_ip}:5000"
    app_svc     = local.dns_enabled ? "http://app-svc.${var.domain_name}:5001" : "http://${aws_instance.app_svc.public_ip}:5001"
    dashboard   = local.dns_enabled ? "http://dashboard.${var.domain_name}:8080" : "http://${aws_instance.dashboard.public_ip}:8080"
  }
}

output "internal_hostnames" {
  description = "Internal hostnames for Kafka and Postgres (used by services within the VPC)"
  value = {
    kafka    = local.dns_enabled ? "kafka.${var.domain_name}" : aws_instance.kafka.private_ip
    postgres = local.dns_enabled ? "postgres.${var.domain_name}" : aws_instance.postgres.private_ip
  }
}

output "domain_name" {
  description = "Base domain name (empty if DNS not configured)"
  value       = var.domain_name
}

output "all_instance_ips" {
  description = "Public and private IP for each of the four instances"
  value = {
    kafka = {
      public_ip  = aws_instance.kafka.public_ip != "" ? aws_instance.kafka.public_ip : "none"
      private_ip = aws_instance.kafka.private_ip
    }
    postgres = {
      public_ip  = aws_instance.postgres.public_ip != "" ? aws_instance.postgres.public_ip : "none"
      private_ip = aws_instance.postgres.private_ip
    }
    payment_svc = {
      public_ip  = aws_instance.payment_svc.public_ip
      private_ip = aws_instance.payment_svc.private_ip
    }
    app_svc = {
      public_ip  = aws_instance.app_svc.public_ip
      private_ip = aws_instance.app_svc.private_ip
    }
  }
}
