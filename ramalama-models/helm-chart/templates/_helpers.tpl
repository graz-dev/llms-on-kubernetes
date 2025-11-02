{{/* Expand the name of the chart. */}}
{{- define "ramalama-models.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name. */}}
{{- define "ramalama-models.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Create chart name and version as used by the chart label. */}}
{{- define "ramalama-models.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "ramalama-models.labels" -}}
helm.sh/chart: {{ include "ramalama-models.chart" . }}
{{ include "ramalama-models.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels */}}
{{- define "ramalama-models.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ramalama-models.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Ramalama server fullname */}}
{{- define "ramalama-models.ramalama.fullname" -}}
{{- printf "%s-ramalama" (include "ramalama-models.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Ramalama server labels */}}
{{- define "ramalama-models.ramalama.labels" -}}
{{ include "ramalama-models.labels" . }}
app.kubernetes.io/component: ramalama
{{- end -}}

{{/* Ramalama server selector labels */}}
{{- define "ramalama-models.ramalama.selectorLabels" -}}
{{ include "ramalama-models.selectorLabels" . }}
app.kubernetes.io/component: ramalama
{{- end -}}

{{/* WebUI fullname */}}
{{- define "ramalama-models.webui.fullname" -}}
{{- printf "%s-webui" (include "ramalama-models.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* WebUI labels */}}
{{- define "ramalama-models.webui.labels" -}}
{{ include "ramalama-models.labels" . }}
app.kubernetes.io/component: webui
{{- end -}}

{{/* WebUI selector labels */}}
{{- define "ramalama-models.webui.selectorLabels" -}}
{{ include "ramalama-models.selectorLabels" . }}
app.kubernetes.io/component: webui
{{- end -}}
