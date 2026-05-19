terraform {
  backend "s3" {
    # Bucket is passed at init time via -backend-config="bucket=<name>"
    # (stored as TF_STATE_BUCKET GitHub secret — never hardcode here)
    #
    # One-time bucket setup (run once from your local machine):
    #   aws s3 mb s3://<bucket-name> --region us-east-1
    #   aws s3api put-bucket-versioning \
    #     --bucket <bucket-name> \
    #     --versioning-configuration Status=Enabled
    #
    # Local init:
    #   terraform init -backend-config="bucket=<bucket-name>"
    key     = "openclaw/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
