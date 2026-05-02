resource "aws_iam_user" "this" {
  name = var.user_name
  path = "/system/"
}

resource "aws_iam_access_key" "this" {
  user = aws_iam_user.this.name
}

# Policy Document defining least-privilege access to the specific bucket
data "aws_iam_policy_document" "s3_access" {
  statement {
    sid    = "AllowS3Actions"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:ListBucketMultipartUploads"
    ]
    
    # Restrict to the specific bucket and its contents
    resources = [
      var.bucket_arn,
      "${var.bucket_arn}/*"
    ]
  }
}

# Attach the policy directly to the user
resource "aws_iam_user_policy" "s3_access" {
  name   = "${var.user_name}-s3-policy"
  user   = aws_iam_user.this.name
  policy = data.aws_iam_policy_document.s3_access.json
}
