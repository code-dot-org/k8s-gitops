{{- define "crossplane.isAnyAWSProviderEnabled" -}}
{{- $providers := .Values.provider.aws | default dict -}}
{{- $state := dict "enabled" false -}}
{{- range $_, $provider := $providers -}}
  {{- if and (kindIs "map" $provider) ($provider.enabled | default false) -}}
    {{- $_ := set $state "enabled" true -}}
  {{- end -}}
{{- end -}}
{{- if $state.enabled -}}
true
{{- end -}}
{{- end -}}
