{{- define "monitoring.roleName" -}}
{{- printf "%s-monitoring-alloy" .Values.codeai_cluster_config.cluster_name -}}
{{- end -}}

{{- define "monitoring.validate" -}}
{{- $config := .Values.codeai_cluster_config -}}
{{- $_ := required "codeai_cluster_config.cluster_name is required" $config.cluster_name -}}
{{- $_ := required "codeai_cluster_config.oidc_provider_arn is required" $config.oidc_provider_arn -}}
{{- $_ := required "codeai_cluster_config.cluster_oidc_issuer_url is required" $config.cluster_oidc_issuer_url -}}
{{- $_ := required "codeai_cluster_config.iam_arn_prefix is required" $config.iam_arn_prefix -}}
{{- $arn := required "amp.workspaceArn is required from the OpenTofu-generated cluster values" .Values.amp.workspaceArn -}}
{{- $url := required "amp.remoteWriteUrl is required from the OpenTofu-generated cluster values" .Values.amp.remoteWriteUrl -}}
{{- $_ := required "amp.region is required from the OpenTofu-generated cluster values" .Values.amp.region -}}
{{- if not (regexMatch "^arn:aws:aps:[a-z0-9-]+:[0-9]{12}:workspace/ws-[a-f0-9-]+$" $arn) -}}
{{- fail "amp.workspaceArn must be an Amazon Managed Service for Prometheus workspace ARN" -}}
{{- end -}}
{{- $parts := splitList ":" $arn -}}
{{- $workspace := trimPrefix "workspace/" (index $parts 5) -}}
{{- if ne (index $parts 3) .Values.amp.region -}}
{{- fail "amp.region must match amp.workspaceArn" -}}
{{- end -}}
{{- if ne (index $parts 4) (index (splitList ":" $config.iam_arn_prefix) 4) -}}
{{- fail "v1 requires AMP in the cluster account; cross-account access needs a separate design" -}}
{{- end -}}
{{- if ne $url (printf "https://aps-workspaces.%s.amazonaws.com/workspaces/%s/api/v1/remote_write" .Values.amp.region $workspace) -}}
{{- fail "amp.remoteWriteUrl must be the HTTPS remote-write endpoint matching amp.workspaceArn and amp.region" -}}
{{- end -}}
{{- $_ := required "metrics.kubeStateMetricsAddress is required" .Values.metrics.kubeStateMetricsAddress -}}
{{- if and (not (index .Values "kube-state-metrics" "enabled")) (eq .Values.metrics.kubeStateMetricsAddress "monitoring-kube-state-metrics.monitoring.svc:8080") -}}
{{- fail "Enable kube-state-metrics or set metrics.kubeStateMetricsAddress to a verified existing exporter" -}}
{{- end -}}
{{- end -}}
