{{/* Generate basic labels */}}
{{- define "tinyllama-gpu-chart.labels" -}}
helm.sh/chart: {{ include "tinyllama-gpu-chart.chart" . }}
{{ include "tinyllama-gpu-chart.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Generate selector labels */}}
{{- define "tinyllama-gpu-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tinyllama-gpu-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Generate chart name */}}
{{- define "tinyllama-gpu-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Generate full chart name */}}
{{- define "tinyllama-gpu-chart.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Generate chart version */}}
{{- define "tinyllama-gpu-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}