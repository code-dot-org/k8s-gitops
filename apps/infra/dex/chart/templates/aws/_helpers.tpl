{{- define "dex.aws.namespace" -}}
crossplane-system
{{- end -}}

{{- define "dex.aws.providerConfigRef" -}}
providerConfigRef:
  name: default
  kind: ClusterProviderConfig
{{- end -}}
