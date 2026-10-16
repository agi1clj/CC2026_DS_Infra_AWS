# Remote state in S3 (bucket created by bootstrap/bootstrap.sh, not by this configuration,
# to avoid a chicken-and-egg problem).
#
# The bucket and region are supplied at init time ("partial configuration"):
#   local: terraform init -backend-config=backend.hcl   (file written by bootstrap.sh)
#   CI:    terraform init -backend-config=...           (from GitHub repository variables)
#
# use_lockfile: S3-native locking (a .tflock object next to the state); no DynamoDB table.
terraform {
  backend "s3" {
    key          = "dev.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
