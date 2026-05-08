resource "aws_security_group" "dashboard" {
  name        = "${var.project_tag}-dashboard-sg"
  description = "Dashboard web UI on 8080; SSH from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Dashboard HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kafdrop UI"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from VPC (use bastion-sg for internet SSH)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_tag}-dashboard-sg" })
}

resource "aws_instance" "dashboard" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.services_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.dashboard.id, aws_security_group.bastion.id]
  key_name                    = var.ssh_key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data_base64 = base64gzip(templatefile("${path.module}/userdata/dashboard.sh", {
    kafka_ip      = aws_instance.kafka.private_ip
    kafka_host    = local.dns_enabled ? "kafka.${var.domain_name}" : aws_instance.kafka.private_ip
    postgres_ip   = aws_instance.postgres.private_ip
    postgres_host = local.dns_enabled ? "postgres.${var.domain_name}" : aws_instance.postgres.private_ip
    payment_ip    = aws_instance.payment_svc.private_ip
    payment_host  = local.dns_enabled ? "payment-svc.${var.domain_name}" : aws_instance.payment_svc.private_ip
    app_ip        = aws_instance.app_svc.private_ip
    app_host      = local.dns_enabled ? "app-svc.${var.domain_name}" : aws_instance.app_svc.private_ip
  }))

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-dashboard"
    Role = "dashboard"
  })

  depends_on = [aws_instance.kafka, aws_instance.postgres, aws_instance.payment_svc, aws_instance.app_svc]
}
