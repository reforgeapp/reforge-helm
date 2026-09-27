{{- define "reforge.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- define "reforge.labels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}
{{- define "reforge.image" -}}
{{ printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end -}}
{{- define "reforge.runnerImage" -}}
{{ printf "%s:%s" .Values.runner.image.repository (default .Chart.AppVersion .Values.runner.image.tag) }}
{{- end -}}
{{- define "reforge.appSecret" -}}
{{ default (printf "%s-app" (include "reforge.fullname" .)) .Values.secrets.existingSecret }}
{{- end -}}
{{- define "reforge.databaseSecret" -}}
{{ default (printf "%s-database" (include "reforge.fullname" .)) .Values.postgresql.existingSecret }}
{{- end -}}
{{- define "reforge.authentikSecret" -}}
{{ default (printf "%s-authentik" (include "reforge.fullname" .)) .Values.authentik.existingSecret }}
{{- end -}}
{{- define "reforge.databaseHost" -}}
{{- if .Values.postgresql.enabled -}}
{{ include "reforge.fullname" . }}-postgresql
{{- else -}}
{{ required "externalDatabase.host is required when postgresql.enabled=false" .Values.externalDatabase.host }}
{{- end -}}
{{- end -}}
{{- define "reforge.databaseName" -}}
{{ ternary "reforge" .Values.externalDatabase.name .Values.postgresql.enabled }}
{{- end -}}
{{- define "reforge.databasePort" -}}
{{ ternary 5432 (int .Values.externalDatabase.port) .Values.postgresql.enabled }}
{{- end -}}
{{- define "reforge.databaseSSLMode" -}}
{{- if .Values.postgresql.enabled -}}
{{ ternary "verify-full" "disable" (not (empty .Values.postgresql.tls.existingSecret)) }}
{{- else -}}
{{ .Values.externalDatabase.sslMode }}
{{- end -}}
{{- end -}}
{{- define "reforge.databaseCASecret" -}}
{{ ternary .Values.postgresql.tls.existingSecret .Values.externalDatabase.caSecret .Values.postgresql.enabled }}
{{- end -}}
{{- define "reforge.oidcIssuer" -}}
{{- if .Values.authentik.enabled -}}
{{ trimSuffix "/" .Values.authentik.publicURL }}/application/o/reforge/
{{- else -}}
{{ required "oidc.issuer is required when authentik.enabled=false" .Values.oidc.issuer }}
{{- end -}}
{{- end -}}
{{- define "reforge.oidcSecret" -}}
{{- if .Values.authentik.enabled -}}
{{ include "reforge.authentikSecret" . }}
{{- else -}}
{{ required "oidc.existingSecret is required when authentik.enabled=false" .Values.oidc.existingSecret }}
{{- end -}}
{{- end -}}
{{- define "reforge.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}

{{- define "reforge.workspaceNamespace" -}}
{{- $namespace := default (printf "%s-%s-workspaces" .Release.Namespace (include "reforge.fullname" .)) .Values.runner.kubernetes.namespace -}}
{{- if gt (len $namespace) 63 -}}
{{- fail "set runner.kubernetes.namespace to a dedicated namespace of at most 63 characters" -}}
{{- end -}}
{{- if eq $namespace .Release.Namespace -}}
{{- fail "runner.kubernetes.namespace must differ from the application namespace" -}}
{{- end -}}
{{- $namespace -}}
{{- end -}}
{{- define "reforge.toolchains" -}}
{{- $toolchains := dict -}}
{{- range $name, $image := .Values.runner.kubernetes.images -}}
{{- $_ := set $toolchains $name (last (splitList "@" $image)) -}}
{{- end -}}
{{- $toolchains | toJson -}}
{{- end -}}
{{- define "reforge.runtimeConfig" -}}
{{- $images := dict -}}
{{- range $name, $image := .Values.runner.kubernetes.images -}}
{{- $_ := set $images (last (splitList "@" $image)) $image -}}
{{- end -}}
{{- $kubernetes := dict "namespace" (include "reforge.workspaceNamespace" .) "runtime_class_name" .Values.runner.kubernetes.runtimeClassName "image_pull_secrets" .Values.runner.kubernetes.imagePullSecrets "images" $images "toolchains" (include "reforge.toolchains" . | fromJson) "broker_listen_address" "0.0.0.0:8086" -}}
{{- dict "backend" "kubernetes" "kubernetes" $kubernetes "memory_bytes" .Values.runner.kubernetes.memoryBytes "disk_bytes" .Values.runner.kubernetes.diskBytes "cpus" .Values.runner.kubernetes.cpus "max_processes" 0 | toJson -}}
{{- end -}}
