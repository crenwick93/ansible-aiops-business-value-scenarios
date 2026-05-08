resource "aws_instance" "kafka" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.kafka_instance_type
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.kafka.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = file("${path.module}/userdata/kafka.sh")

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-kafka"
    Role = "kafka"
  })
}
