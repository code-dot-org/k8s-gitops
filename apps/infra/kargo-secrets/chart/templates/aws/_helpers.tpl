{{- define "kargo-secrets.aws.namespace" -}}
crossplane-system
{{- end -}}

{{- define "kargo-secrets.aws.providerConfigRef" -}}
providerConfigRef:
  name: default
  kind: ClusterProviderConfig
{{- end -}}
