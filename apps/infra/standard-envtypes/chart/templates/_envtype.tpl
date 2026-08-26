{{- define "eso-per-envtype.render" -}}
{{- if .single_namespace_environment_type }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .environment_type }}
---
{{- end }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa-{{ .environment_type }}
  namespace: {{ ternary .environment_type "external-secrets" .single_namespace_environment_type }}
  annotations:
    eks.amazonaws.com/role-arn: {{ .iam_role_arn | quote }}
---
{{- if .single_namespace_environment_type }}
#==============================================================================
# Per-k8s-namespace SecretStore : aws-secrets-manager-store in kubernetes
#
# This is installed in "one namespace per environment type" situations, namely:
# - staging, levelbuilder, test, and production
#==============================================================================
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets-manager-store
  namespace: {{ .environment_type }}
spec:
  provider:
    aws:
      service: SecretsManager
      region: {{ .region | quote }}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa-{{ .environment_type }}
{{- else }}
#==============================================================================
# ClusterSecretStore : aws-secrets-manager-store-${env_type} in kubernetes
#
# This is installed in "multiple namespace per env type" situations, namely:
# - adhoc, where all adhoc-* namespaces will have access to this ClusterSecretStore
#==============================================================================
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager-store-{{ .environment_type }}
spec:
  conditions:
    - namespaceRegexes:
{{ toYaml .multi_namespace_regexes | indent 8 }}
  provider:
    aws:
      service: SecretsManager
      region: {{ .region | quote }}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa-{{ .environment_type }}
            namespace: external-secrets
{{- end }}
---
{{- if .single_namespace_environment_type }}
#==============================================================================
# Per-k8s-namespace ExternalSecret : cdo-external-secrets in kubernetes
#
# This syncs all secrets like {namespace}/cdo/* from AWS Secrets Manager into a
# single Kubernetes Secret named cdo-external-secrets.
#==============================================================================
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cdo-external-secrets
  namespace: {{ .environment_type }}
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: aws-secrets-manager-store
    kind: SecretStore
  target:
    # These four fields (here and in each find block below) are the CRD
    # defaults. We declare them anyway: if we omit them the API server fills
    # them in at admission, and Argo then reports the difference between our
    # manifest and the live object as permanent drift. Declaring them keeps
    # desired == live and needs no ignoreDifferences in application.yaml.
    creationPolicy: Owner
    deletionPolicy: Retain
    name: cdo-external-secrets
{{- if .compose_db_urls }}
    template:
      engineVersion: v2
      # Merge renders these keys on top of the dataFrom-synced keys; the
      # default (Replace) would drop every other key from the Secret.
      mergePolicy: Merge
      data:
        # Compose the app's mysql:// URLs from the CloudFormation-provisioned
        # credentials and cluster writer endpoint synced by the CfnStack find
        # block below. This overrides the <env>/cdo/db_writer and db_reader
        # values, which have been frozen since 2019 and reference the retired
        # `application-writer` MySQL user (renamed to `writer` and put under
        # Custom::SQLUser provisioning in code-dot-org #52796/#56431).
        #
        # The credential passwords are generated with ExcludePunctuation, so
        # embedding them in a URL without percent-encoding is safe. db_reader
        # uses the SELECT-only `reader` user against the writer endpoint:
        # CloudFormation publishes no direct reader endpoint, and routing reads
        # through the RDS Proxy reader endpoint is a separate decision.
        #
        # Every key referenced here must exist in Secrets Manager for each env
        # type this renders for (see compose_db_url_environment_types in
        # values.yaml): a missing key fails the entire Secret sync.
        db_writer: {{ `mysql://{{ (.db_credential_writer | fromJson).username }}:{{ (.db_credential_writer | fromJson).password }}@{{ .db_endpoint_writer }}:{{ .db_endpoint_writer_port }}/` | quote }}
        db_reader: {{ `mysql://{{ (.db_credential_reader | fromJson).username }}:{{ (.db_credential_reader | fromJson).password }}@{{ .db_endpoint_writer }}:{{ .db_endpoint_writer_port }}/` | quote }}
{{- end }}
  dataFrom:
    - find:
        conversionStrategy: Default
        decodingStrategy: None
        path: {{ printf "%s/cdo/" .environment_type | quote }}
        name:
          regexp: {{ printf "^%s/cdo/.*$" .environment_type | quote }}
      rewrite:
        - regexp:
            source: {{ printf "^%s/cdo/(.*)$" .environment_type | quote }}
            target: "$1"
    #==========================================================================
    # CloudFormation-provisioned DB endpoints and credentials.
    #
    # dashboard declares these as !StackSecret (code-dot-org config.yml.erb),
    # which resolves by reading the EC2 instance's aws:cloudformation:stack-name
    # tag. There is no EC2 instance in Kubernetes, so that resolution cannot
    # work; syncing the secrets here instead means pods read them as CDO_* env
    # vars and never call Secrets Manager at boot.
    #
    # Only single-namespace env types get this. Adhoc deployments have one
    # CloudFormation stack per adhoc, so there is no CfnStack/adhoc/* path, and
    # the multi-namespace IAM policy does not grant one.
    #
    # Matched on the db_ prefix rather than the whole path: every key dashboard
    # needs from here starts with db_ (db_cluster_id, db_endpoint_*,
    # db_credential_*), and CfnStack/<env>/ also holds unrelated keys such as
    # `chef` that would otherwise be swept in. RE2 has no negative lookahead, so
    # a positive match is the way to express this -- and it stays correct as
    # other things get filed under this prefix.
    #
    # NOTE: dataFrom entries merge in order, so a key present under both paths
    # takes its value from this second entry. The db_credential_* keys ARE
    # present under both (e.g. staging/cdo/db_credential_writer exists alongside
    # CfnStack/staging/db_credential_writer), and the CfnStack value winning is
    # intended: it is the live, CloudFormation-managed credential, while the
    # <env>/cdo/ copies are frozen 2019-era values.
    #==========================================================================
    - find:
        conversionStrategy: Default
        decodingStrategy: None
        path: {{ printf "CfnStack/%s/" .environment_type | quote }}
        name:
          regexp: {{ printf "^CfnStack/%s/db_.*$" .environment_type | quote }}
      rewrite:
        - regexp:
            source: {{ printf "^CfnStack/%s/(.*)$" .environment_type | quote }}
            target: "$1"
{{- else }}
#==============================================================================
# ClusterExternalSecret fanout for multi-namespace env types like adhoc-*
#
# ClusterExternalSecret selects namespaces by label, not by regex. To have all
# adhoc-* namespaces receive this ExternalSecret, label them with:
# code.org/environment-type = adhoc
#==============================================================================
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: cdo-external-secrets-{{ .environment_type }}
spec:
  externalSecretName: cdo-external-secrets
  namespaceSelectors:
    - matchLabels:
        code.org/environment-type: {{ .environment_type | quote }}
  refreshTime: 1m
  externalSecretSpec:
    refreshInterval: 5m
    secretStoreRef:
      name: aws-secrets-manager-store-{{ .environment_type }}
      kind: ClusterSecretStore
    target:
      # CRD defaults, declared to avoid Argo drift. See the ExternalSecret
      # branch above.
      creationPolicy: Owner
      deletionPolicy: Retain
      name: cdo-external-secrets
    dataFrom:
      - find:
          conversionStrategy: Default
          decodingStrategy: None
          path: {{ printf "%s/cdo/" .environment_type | quote }}
          name:
            regexp: {{ printf "^%s/cdo/.*$" .environment_type | quote }}
        rewrite:
          - regexp:
              source: {{ printf "^%s/cdo/(.*)$" .environment_type | quote }}
              target: "$1"
{{- end }}
{{- end -}}
