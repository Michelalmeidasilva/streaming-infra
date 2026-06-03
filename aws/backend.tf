terraform {
  backend "s3" {
    bucket       = "vod-tfstate-prod-use2"
    key          = "aws/foundation/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
