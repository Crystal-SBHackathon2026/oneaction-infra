output "review_docs_bucket_name" {
  value = aws_s3_bucket.review_docs.id
}

output "logs_bucket_name" {
  value = aws_s3_bucket.logs.id
}

output "logs_bucket_arn" {
  value = aws_s3_bucket.logs.arn
}
