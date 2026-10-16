# Same S3 bucket as the application state, separate key. Applied only locally by
# bootstrap/bootstrap.sh (with your own AWS login): GitHub Actions never changes the
# roles it runs as.
terraform {
  backend "s3" {
    key          = "bootstrap.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
