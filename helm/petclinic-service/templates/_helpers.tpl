{{/*
Expand the name of the chart.
*/}}
{{- define "petclinic-service.name" -}}
{{- .Release.Name }}
{{- end }}

{{/*
Common labels — applied to all resources.
app.kubernetes.io/component defaults to "service" but can be overridden
via .Values.component in per-service values files.
*/}}
{{- define "petclinic-service.labels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/component: {{ .Values.component | default "service" }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}

{{/*
Selector labels — used for matchLabels in Deployment and Service.
Must be stable — do NOT include version or component here
as changing them would break rolling updates.
*/}}
{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
