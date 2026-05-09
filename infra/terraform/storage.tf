resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "document_uploads" {
  bucket = "${var.project_tag}-passport-documents-${random_id.bucket_suffix.hex}"

  tags = merge(local.common_tags, {
    Name = "passport-document-uploads"
  })
}

resource "aws_s3_object" "sample_uploads" {
  for_each = toset([
    "photos/applicant_001.jpg",
    "photos/applicant_002.jpg",
    "photos/applicant_003.jpg",
    "documents/birth_cert_001.pdf",
    "documents/birth_cert_002.pdf",
    "documents/deed_poll_003.pdf",
    "documents/countersignatory_004.pdf",
    "scans/old_passport_001.pdf",
    "scans/old_passport_002.pdf",
    "scans/old_passport_005.pdf",
  ])

  bucket  = aws_s3_bucket.document_uploads.id
  key     = each.value
  content = "sample-file-placeholder"

  tags = local.common_tags
}

resource "aws_iam_user" "aap_storage_readonly" {
  name = "${var.project_tag}-storage-diag-readonly"
  tags = local.common_tags
}

resource "aws_iam_user_policy" "s3_read_only" {
  name = "s3-single-bucket-read-only"
  user = aws_iam_user.aap_storage_readonly.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:HeadBucket", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.document_uploads.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.document_uploads.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_access_key" "aap_storage_readonly" {
  user = aws_iam_user.aap_storage_readonly.name
}
