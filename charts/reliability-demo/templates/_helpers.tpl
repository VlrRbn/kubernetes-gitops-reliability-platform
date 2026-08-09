{{- define "reliability-demo.name" -}}
reliability-demo
{{- end }}

{{- define "reliability-demo.fullname" -}}
{{- printf "%s" (include "reliability-demo.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "reliability-demo.labels" -}}
app.kubernetes.io/name: {{ include "reliability-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "reliability-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "reliability-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "reliability-demo.image" -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end -}}
{{- end }}
