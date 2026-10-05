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
{{- define "reforge.staffSecret" -}}
{{ printf "%s-staff-database" (include "reforge.fullname" .) }}
{{- end -}}
{{- define "reforge.builtinRunnerSecret" -}}
{{ printf "%s-builtin-runner" (include "reforge.fullname" .) }}
{{- end -}}
{{- define "reforge.builtinInit" -}}
- name: builtin-init
  image: {{ include "reforge.runnerImage" . | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: [/bin/sh, -ec]
  args:
    - |
      cp /runtime-source/runtime.json /builtin/runtime.json
      cp /builtin-secret/token /builtin/token
      chmod 0640 /builtin/runtime.json /builtin/token
      exec /app/reforge-runner builtin-init --dir /builtin --runtime-config /builtin/runtime.json
  env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
  securityContext:
    runAsUser: 10002
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: builtin
      mountPath: /builtin
    - name: runtime-source
      mountPath: /runtime-source
      readOnly: true
    - name: builtin-secret
      mountPath: /builtin-secret
      readOnly: true
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
    limits:
      memory: 256Mi
{{- end -}}
{{- define "reforge.builtinVolumes" -}}
- name: builtin
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
- name: runtime-source
  configMap:
    name: {{ include "reforge.fullname" . }}-runner
- name: builtin-secret
  secret:
    secretName: {{ include "reforge.builtinRunnerSecret" . }}
    defaultMode: 0440
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
{{- with .Values.runner.kubernetes.cache }}
{{- if .bytes }}
{{- $_ := set $kubernetes "cache_bytes" (int64 .bytes) }}
{{- $_ := set $kubernetes "cache_access_mode" .accessMode }}
{{- if .storageClass }}{{ $_ := set $kubernetes "cache_storage_class" .storageClass }}{{ end }}
{{- end }}
{{- end }}
{{- dict "backend" "kubernetes" "kubernetes" $kubernetes "memory_bytes" .Values.runner.kubernetes.memoryBytes "disk_bytes" .Values.runner.kubernetes.diskBytes "cpus" .Values.runner.kubernetes.cpus "max_processes" 0 | toJson -}}
{{- end -}}

{{- define "reforge.edition" -}}
{{- if not (has .Values.edition (list "self-hosted" "hosted")) -}}
{{- fail "edition must be self-hosted or hosted" -}}
{{- end -}}
{{- if and (eq .Values.edition "hosted") .Values.secrets.bootstrap.enabled -}}
{{- fail "edition=hosted requires secrets.bootstrap.enabled=false" -}}
{{- end -}}
{{- if and .Values.githubApp.existingSecret (ne .Values.edition "hosted") -}}
{{- fail "githubApp is only supported with edition=hosted" -}}
{{- end -}}
{{- .Values.edition -}}
{{- end -}}
