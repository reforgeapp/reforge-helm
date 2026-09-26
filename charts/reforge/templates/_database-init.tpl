{{- define "reforge.databaseInit" -}}
- name: database-urls
  image: {{ .Values.provisioning.image | quote }}
  command: [python3, /database-scripts/database-urls.py]
  env:
    - name: DATABASE_HOST
      value: {{ include "reforge.databaseHost" . | quote }}
    - name: DATABASE_PORT
      value: {{ include "reforge.databasePort" . | quote }}
    - name: DATABASE_NAME
      value: {{ include "reforge.databaseName" . | quote }}
    - name: DATABASE_SSLMODE
      value: {{ include "reforge.databaseSSLMode" . | quote }}
    - name: DATABASE_CA
      value: {{ ternary "/database-ca/ca.crt" "" (not (empty (include "reforge.databaseCASecret" .))) | quote }}
    - name: RUNTIME_USER
      value: {{ ternary "reforge_runtime" .Values.externalDatabase.runtimeUser .Values.postgresql.enabled | quote }}
    - name: MIGRATOR_USER
      value: {{ ternary "reforge_migrator" .Values.externalDatabase.migratorUser .Values.postgresql.enabled | quote }}
    - name: RUNTIME_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: runtime-password
    - name: MIGRATOR_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: migrator-password
  securityContext:
    runAsUser: 10001
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: database-scripts
      mountPath: /database-scripts
      readOnly: true
    - name: database
      mountPath: /database
    - name: migration
      mountPath: /migration
  resources:
    requests: {cpu: 25m, memory: 32Mi}
    limits: {memory: 128Mi}
{{- if .Values.postgresql.enabled }}
- name: database-roles
  image: {{ .Values.postgresql.image | quote }}
  command: [/bin/sh, -ec]
  args:
    - |
      attempts=0
      until psql -X -Atqc 'SELECT 1' >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 120 ] || { echo 'PostgreSQL did not become ready' >&2; exit 1; }
        sleep 5
      done
      psql -X -v ON_ERROR_STOP=1 -f /database-scripts/roles.sql
      {{- if .Values.authentik.enabled }}
      psql -X -v ON_ERROR_STOP=1 -f /database-scripts/authentik.sql
      {{- end }}
  env:
    - name: PGHOST
      value: {{ include "reforge.databaseHost" . | quote }}
    - name: PGDATABASE
      value: reforge
    - name: PGUSER
      value: postgres
    - name: PGSSLMODE
      value: {{ include "reforge.databaseSSLMode" . | quote }}
    {{- if include "reforge.databaseCASecret" . }}
    - name: PGSSLROOTCERT
      value: /database-ca/ca.crt
    {{- end }}
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: admin-password
    - name: REFORGE_MIGRATOR_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: migrator-password
    - name: REFORGE_RUNTIME_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: runtime-password
    - name: REFORGE_MIGRATION_DATABASE_URL
      value: unused
    - name: REFORGE_DATABASE_URL
      value: unused
    {{- if .Values.authentik.enabled }}
    - name: AUTHENTIK_DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.authentikSecret" . }}
          key: database-password
    {{- end }}
  securityContext:
    runAsUser: 70
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: database-scripts
      mountPath: /database-scripts
      readOnly: true
    {{- if include "reforge.databaseCASecret" . }}
    - name: database-ca
      mountPath: /database-ca
      readOnly: true
    {{- end }}
  resources:
    requests: {cpu: 50m, memory: 32Mi}
    limits: {memory: 128Mi}
{{- end }}
- name: schema
  image: {{ include "reforge.image" . | quote }}
  command: [/bin/sh, -ec]
  args:
    - |
      . /migration/migration.env
      export REFORGE_MIGRATION_DATABASE_URL
      exec /app/reforge-migrate
  securityContext:
    runAsUser: 10001
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: migration
      mountPath: /migration
      readOnly: true
    {{- if include "reforge.databaseCASecret" . }}
    - name: database-ca
      mountPath: /database-ca
      readOnly: true
    {{- end }}
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {memory: 512Mi}
- name: runtime-grants
  image: {{ .Values.postgresql.image | quote }}
  command: [psql, -X, -v, ON_ERROR_STOP=1, -f, /database-scripts/runtime-grants.sql]
  env:
    - name: PGHOST
      value: {{ include "reforge.databaseHost" . | quote }}
    - name: PGPORT
      value: {{ include "reforge.databasePort" . | quote }}
    - name: PGDATABASE
      value: {{ include "reforge.databaseName" . | quote }}
    - name: PGUSER
      value: {{ ternary "reforge_migrator" .Values.externalDatabase.migratorUser .Values.postgresql.enabled | quote }}
    - name: RUNTIME_USER
      value: {{ ternary "reforge_runtime" .Values.externalDatabase.runtimeUser .Values.postgresql.enabled | quote }}
    - name: PGSSLMODE
      value: {{ include "reforge.databaseSSLMode" . | quote }}
    {{- if include "reforge.databaseCASecret" . }}
    - name: PGSSLROOTCERT
      value: /database-ca/ca.crt
    {{- end }}
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "reforge.databaseSecret" . }}
          key: migrator-password
  securityContext:
    runAsUser: 70
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: database-scripts
      mountPath: /database-scripts
      readOnly: true
    {{- if include "reforge.databaseCASecret" . }}
    - name: database-ca
      mountPath: /database-ca
      readOnly: true
    {{- end }}
  resources:
    requests: {cpu: 50m, memory: 32Mi}
    limits: {memory: 128Mi}
- name: oidc-ready
  image: {{ .Values.provisioning.image | quote }}
  command: [python3, /database-scripts/wait-oidc.py]
  env:
    - name: OIDC_ISSUER
      value: {{ include "reforge.oidcIssuer" . | quote }}
  securityContext:
    runAsUser: 10001
    {{- include "reforge.securityContext" . | nindent 4 }}
  volumeMounts:
    - name: database-scripts
      mountPath: /database-scripts
      readOnly: true
  resources:
    requests: {cpu: 25m, memory: 32Mi}
    limits: {memory: 128Mi}
{{- end -}}
