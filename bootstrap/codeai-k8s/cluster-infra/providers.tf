provider "aws" {
  region = local.cluster_region
  default_tags {
    tags = {
      "environment-type" = "k8s"
    }
  }
}

provider "github" {
  alias = "admin"
  owner = "code-dot-org"
}

provider "github" {
  alias = "kargo_k8s_gitops"
  owner = "code-dot-org"
}
