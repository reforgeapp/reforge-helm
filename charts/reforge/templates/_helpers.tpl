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
