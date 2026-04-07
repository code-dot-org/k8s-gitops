{{- define "aws-resources.namespace" -}}
crossplane-system
{{- end -}}

{{- define "aws-resources.providerConfigRef" -}}
providerConfigRef:
  name: default
  kind: ClusterProviderConfig
{{- end -}}
