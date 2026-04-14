#===============================================================
# Bootstrap Argo CD itself from the local k8s-gitops checkout.
#
# After this initial install, Argo CD will self-manage the same chart
# from apps/infra/argocd/chart in this repo.
#===============================================================

data "github_repository" "k8s_gitops" {
  full_name = "code-dot-org/k8s-gitops"
}

resource "helm_release" "argocd_bootstrap" {
  name             = "argocd"
  chart            = "${path.module}/../../../apps/infra/argocd/chart"
  namespace        = "argocd"
  create_namespace = true
  values = [
    yamlencode({
      # Blank-cluster bootstrap needs the one-time Redis secret-init hook.
      # The steady-state chart values in k8s-gitops disable it so self-managed
      # Argo does not keep resuming this hook on itself:
      # https://github.com/argoproj/argo-helm/issues/2887
      argo-cd = {
        redisSecretInit = {
          enabled = true
        }
        server = {
          ingress = {
            enabled = false
          }
        }
      }
      _bootstrap = {}
    })
  ]

  lifecycle {
    ignore_changes = all
  }
}
