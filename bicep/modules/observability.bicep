// Observability for the platform (report section 4.3): SLO-based log alerts and an operations workbook,
// both reading the Log Analytics workspace that Container Insights fills (container logs incl. the Traefik
// access log, pod inventory, node performance). Queries live in observability/kql/*.kql, shared by alerts
// and workbook and validated against real data (k6 load/stress test of 2026-11-25). Runbook: docs/runbook.md.

@description('Azure region for the alert rules and the workbook.')
param location string

@description('Naming prefix, e.g. oc3d-dev.')
param namePrefix string

@description('Resource id of the Log Analytics workspace the queries run on.')
param workspaceId string

@description('E-mail addresses notified by the action group. Empty: alerts only show in Azure Monitor.')
param alertEmails array = []

@description('maxReplicas of the clinical HPA (deploy/k8s/clinical.yaml); the capacity alert fires at it.')
param clinicalHpaMaxReplicas int = 3

@description('Availability SLO for clinical, in percent of requests without a 5xx.')
param availabilitySloPct int = 995

@description('Latency SLO for clinical: p95 in milliseconds.')
param latencySloP95Ms int = 800

param tags object = {}

var docsUrl = 'https://github.com/OnControl3D-ASF/oncontrol3d-infra/blob/main/docs/runbook.md'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${namePrefix}-ops'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'oc3d-ops'
    enabled: true
    emailReceivers: [for (email, i) in alertEmails: {
      name: 'email-${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

// One entry per alert. availabilitySloPct is in tenths of a percent (995 = 99.5 %) because Bicep params are integers.
var alerts = [
  {
    key: 'clinical-availability'
    displayName: 'clinical: availability below SLO'
    description: 'Less than ${availabilitySloPct / 10}.${availabilitySloPct % 10} % of clinical requests answered without 5xx in 15 min. Runbook: ${docsUrl}#clinical-availability'
    severity: 1
    window: 'PT15M'
    query: loadTextContent('observability/kql/clinical-availability.kql')
    aggregation: 'Minimum'
    column: 'AvailabilityPct'
    operator: 'LessThan'
    threshold: json('${availabilitySloPct / 10}.${availabilitySloPct % 10}')
    dimensions: []
  }
  {
    key: 'clinical-latency'
    displayName: 'clinical: p95 latency above SLO'
    description: 'p95 of clinical requests above ${latencySloP95Ms} ms over 15 min. Runbook: ${docsUrl}#clinical-latency'
    severity: 2
    window: 'PT15M'
    query: loadTextContent('observability/kql/clinical-latency.kql')
    aggregation: 'Maximum'
    column: 'P95Ms'
    operator: 'GreaterThan'
    threshold: latencySloP95Ms
    dimensions: []
  }
  {
    key: 'pods-unhealthy'
    displayName: 'oncontrol: pods failing'
    description: 'At least one application pod in CrashLoopBackOff, ImagePullBackOff, OOMKilled or Failed. Runbook: ${docsUrl}#pods-unhealthy'
    severity: 1
    window: 'PT10M'
    query: loadTextContent('observability/kql/pods-unhealthy.kql')
    aggregation: 'Maximum'
    column: 'UnhealthyPods'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: []
  }
  {
    key: 'clinical-hpa-at-max'
    displayName: 'clinical: HPA at maximum replicas'
    description: 'clinical ran at ${clinicalHpaMaxReplicas} replicas (HPA max) for 10 min: no autoscaling headroom left. Runbook: ${docsUrl}#clinical-hpa-at-max'
    severity: 3
    window: 'PT10M'
    query: loadTextContent('observability/kql/clinical-hpa-at-max.kql')
    aggregation: 'Minimum'
    column: 'MinReplicas'
    operator: 'GreaterThanOrEqual'
    threshold: clinicalHpaMaxReplicas
    dimensions: []
  }
  {
    key: 'node-cpu'
    displayName: 'AKS: node CPU above 80 %'
    description: 'A node used more than 80 % of its allocatable CPU on average over 15 min. Runbook: ${docsUrl}#node-cpu'
    severity: 2
    window: 'PT15M'
    query: loadTextContent('observability/kql/node-cpu.kql')
    aggregation: 'Average'
    column: 'CpuPct'
    operator: 'GreaterThan'
    threshold: 80
    dimensions: [
      {
        name: 'Computer'
        operator: 'Include'
        values: ['*']
      }
    ]
  }
]

resource alertRules 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for alert in alerts: {
  name: 'alert-${namePrefix}-${alert.key}'
  location: location
  tags: tags
  properties: {
    displayName: alert.displayName
    description: alert.description
    severity: alert.severity
    enabled: true
    scopes: [workspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: alert.window
    criteria: {
      allOf: [
        {
          query: alert.query
          timeAggregation: alert.aggregation
          metricMeasureColumn: alert.column
          operator: alert.operator
          threshold: alert.threshold
          dimensions: alert.dimensions
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}]

// Workbook: one query item per chart, all bound to the TimeRange parameter.
var workspaceResourceType = 'microsoft.operationalinsights/workspaces'
var chartItems = [
  {
    name: 'sli-summary'
    title: 'SLIs por servicio (edge / Traefik) frente a los SLOs'
    file: loadTextContent('observability/kql/wb-sli-summary.kql')
    visualization: 'table'
    width: '100'
  }
  {
    name: 'requests'
    title: 'Tráfico: requests por minuto y servicio'
    file: loadTextContent('observability/kql/wb-requests-trend.kql')
    visualization: 'timechart'
    width: '50'
  }
  {
    name: 'errors'
    title: 'Errores: respuestas 5xx por minuto y servicio'
    file: loadTextContent('observability/kql/wb-errors-trend.kql')
    visualization: 'timechart'
    width: '50'
  }
  {
    name: 'latency'
    title: 'Latencia de clinical: p50 y p95 por minuto (SLO p95 = 800 ms)'
    file: loadTextContent('observability/kql/wb-clinical-latency-trend.kql')
    visualization: 'linechart'
    width: '50'
  }
  {
    name: 'replicas'
    title: 'Saturación: réplicas de clinical (HPA 1–3)'
    file: loadTextContent('observability/kql/wb-clinical-replicas-trend.kql')
    visualization: 'linechart'
    width: '50'
  }
  {
    name: 'node-cpu'
    title: 'Saturación: CPU de nodos (% de lo asignable)'
    file: loadTextContent('observability/kql/wb-node-cpu-trend.kql')
    visualization: 'linechart'
    width: '100'
  }
]

var workbookContent = {
  version: 'Notebook/1.0'
  items: concat(
    [
      {
        type: 1
        name: 'header'
        content: {
          json: '## OnControl3D — Operaciones (${namePrefix})\nSeñales doradas medidas en el edge (access log de Traefik) y en el clúster (Container Insights). SLOs de clinical: disponibilidad ≥ 99.5 % y p95 < 800 ms. Alertas y runbook: [docs/runbook.md](${docsUrl}).'
        }
      }
      {
        type: 9
        name: 'parameters'
        content: {
          version: 'KqlParameterItem/1.0'
          parameters: [
            {
              id: '7d3f0a52-4b7c-4c1e-9a43-2f0f3c1d5e61'
              version: 'KqlParameterItem/1.0'
              name: 'TimeRange'
              label: 'Rango'
              type: 4
              isRequired: true
              value: {
                durationMs: 14400000
              }
              typeSettings: {
                selectableValues: [
                  { durationMs: 3600000 }
                  { durationMs: 14400000 }
                  { durationMs: 43200000 }
                  { durationMs: 86400000 }
                  { durationMs: 604800000 }
                ]
                allowCustom: true
              }
            }
          ]
          style: 'pills'
          queryType: 0
          resourceType: workspaceResourceType
        }
      }
    ],
    map(chartItems, item => {
      type: 3
      name: item.name
      customWidth: item.width
      content: {
        version: 'KqlItem/1.0'
        query: item.file
        size: 0
        title: item.title
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceResourceType
        visualization: item.visualization
      }
    })
  )
  isLocked: false
  fallbackResourceIds: [workspaceId]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, namePrefix, 'operations-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'OnControl3D — Operaciones (${namePrefix})'
    category: 'workbook'
    sourceId: workspaceId
    serializedData: string(workbookContent)
    version: '1.0'
  }
}

output actionGroupId string = actionGroup.id
output workbookId string = workbook.id
output alertRuleNames array = [for (alert, i) in alerts: alertRules[i].name]
