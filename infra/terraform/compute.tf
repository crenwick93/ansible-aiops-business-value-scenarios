# Minimal IAM: SSM for Session Manager and agent convenience; no other AWS API calls required for apps.
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_tag}-ec2-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json

  tags = merge(local.common_tags, { Name = "${var.project_tag}-ec2-instance-role" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_tag}-ec2-instance-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, { Name = "${var.project_tag}-ec2-instance-profile" })
}
