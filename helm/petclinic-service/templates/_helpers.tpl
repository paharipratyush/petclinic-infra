{{/*
Expand the name of the chart.
*/}}
{{- define "petclinic-service.name" -}}
{{- .Release.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "petclinic-service.labels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: petclinic
{{- end }}

{{/*
Selector labels
*/}}
{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
