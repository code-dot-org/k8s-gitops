data "terraform_remote_state" "observability" {
  backend = "s3"
  config = {
    bucket = "codeai-tofu-state"
    key    = "observability/production/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  monitoring_amp = {
    workspaceArn   = data.terraform_remote_state.observability.outputs.prometheus_workspace_arn
    remoteWriteUrl = data.terraform_remote_state.observability.outputs.prometheus_remote_write_url
    region         = split(":", data.terraform_remote_state.observability.outputs.prometheus_workspace_arn)[3]
  }
}
