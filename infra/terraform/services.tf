resource "aws_instance" "payment_svc" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.services_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.services.id, aws_security_group.bastion.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/userdata/payment-svc.sh", {
    kafka_ip   = aws_instance.kafka.private_ip
    kafka_host = local.dns_enabled ? "kafka.${var.domain_name}" : aws_instance.kafka.private_ip
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-payment-svc"
    Role = "payment-svc"
  })

  depends_on = [aws_instance.kafka]
}

resource "aws_instance" "app_svc" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.services_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.services.id, aws_security_group.bastion.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/userdata/app-svc.sh", {
    kafka_ip      = aws_instance.kafka.private_ip
    kafka_host    = local.dns_enabled ? "kafka.${var.domain_name}" : aws_instance.kafka.private_ip
    postgres_ip   = aws_instance.postgres.private_ip
    postgres_host = local.dns_enabled ? "postgres.${var.domain_name}" : aws_instance.postgres.private_ip
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-app-svc"
    Role = "app-svc"
  })

  depends_on = [aws_instance.kafka, aws_instance.postgres]
}
