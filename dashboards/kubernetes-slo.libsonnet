// Kubernetes SLO Dashboard — Production-grade multi-signal observability
//
// Tracks SLO burn rates, availability, latency, and Kubernetes-specific
// health signals (pod restarts, OOM kills, HPA status, resource pressure)
// for services running in Kubernetes.
//
// Layout:
//   Row 1: SLO Health Summary — error budget, burn rates, latency compliance
//   Row 2: Availability & Error Rates — multi-window burn, SLO threshold
//   Row 3: Latency SLO — p50/p95/p99 with SLO threshold lines
//   Row 4: Kubernetes Pod Health — restarts, OOM kills, pending, not-ready
//   Row 5: Resource Pressure — CPU throttling, memory saturation, HPA
//   Row 6: Alert Status — active SLO and K8s alerts
//
// Usage:
//   jsonnet -J vendor dashboards/kubernetes-slo.libsonnet > /tmp/k8s-slo.json
//
// Recording rules:
//   observability-as-code/recording-rules/kubernetes-slo.yaml
//

local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local gaugePanel = grafana.gaugePanel;
local row = grafana.row;
local template = grafana.template;
local prometheus = grafana.target.prometheus;

// ─── SLO Constants ──────────────────────────────────────────────────────────

local SLO_AVAILABILITY = 0.999;    // 99.9%
local SLO_LATENCY_P99_MS = 500;    // 500ms p99 threshold
local SLO_LATENCY_P95_MS = 200;    // 200ms p95 threshold
local ERROR_RATE_THRESHOLD = (1 - SLO_AVAILABILITY) * 100;  // 0.1%

// Multi-window burn rate thresholds (Google SRE Workbook)
local BURN_FAST = 14.4;   // 1h window — pages immediately
local BURN_SLOW = 6.0;    // 6h window — ticket urgently

// ─── Template Variables ──────────────────────────────────────────────────────

local datasourceVar = template.datasource(
  name='datasource',
  label='Datasource',
  query='prometheus',
  hide='',
);

local clusterVar = template.new(
  name='cluster',
  label='Cluster',
  datasource='$datasource',
  query='label_values(kube_node_info, cluster)',
  multi=false,
  includeAll=false,
  refresh=2,
);

local namespaceVar = template.new(
  name='namespace',
  label='Namespace',
  datasource='$datasource',
  query='label_values(kube_namespace_labels{cluster=~"$cluster"}, namespace)',
  multi=true,
  includeAll=true,
  allValues='.*',
  refresh=2,
);

local workloadVar = template.new(
  name='workload',
  label='Workload',
  datasource='$datasource',
  query='label_values(kube_deployment_labels{cluster=~"$cluster",namespace=~"$namespace"}, deployment)',
  multi=true,
  includeAll=true,
  allValues='.*',
  refresh=2,
);

// ─── Helper: Build Prometheus error rate query ───────────────────────────────

local errorRateQuery(window) =
  |||
    sum(
      rate(http_requests_total{
        cluster=~"$cluster",
        namespace=~"$namespace",
        deployment=~"$workload",
        status_code=~"5.."
      }[%(w)s])
    )
    /
    sum(
      rate(http_requests_total{
        cluster=~"$cluster",
        namespace=~"$namespace",
        deployment=~"$workload"
      }[%(w)s])
    )
  ||| % { w: window };

local burnRateQuery(window) =
  '(%s) / %s' % [errorRateQuery(window), 1 - SLO_AVAILABILITY];

local latencyQuery(quantile, window) =
  |||
    histogram_quantile(%(q)s,
      sum by (le) (
        rate(http_request_duration_seconds_bucket{
          cluster=~"$cluster",
          namespace=~"$namespace",
          deployment=~"$workload"
        }[%(w)s])
      )
    ) * 1000
  ||| % { q: quantile, w: window };

// ─── Row 1: SLO Health Summary ───────────────────────────────────────────────

local errorBudgetPanel = statPanel.new(
  title='Error Budget Remaining (30d)',
  datasource='$datasource',
  unit='percentunit',
  reducerFunction='last',
  colorMode='background',
  graphMode='area',
)
.addThreshold({ color: 'red', value: null })
.addThreshold({ color: 'red', value: 0 })
.addThreshold({ color: 'orange', value: 0.1 })
.addThreshold({ color: 'yellow', value: 0.25 })
.addThreshold({ color: 'green', value: 0.5 })
.addTarget(prometheus.target(
  |||
    1 - (
      sum(
        increase(http_requests_total{
          cluster=~"$cluster",
          namespace=~"$namespace",
          deployment=~"$workload",
          status_code=~"5.."
        }[30d])
      )
      /
      sum(
        increase(http_requests_total{
          cluster=~"$cluster",
          namespace=~"$namespace",
          deployment=~"$workload"
        }[30d])
      )
    ) / (1 - %(slo)s)
  ||| % { slo: SLO_AVAILABILITY },
  legendFormat='Error Budget',
))
+ { gridPos: { x: 0, y: 0, w: 4, h: 4 } };

local fastBurnStatPanel = statPanel.new(
  title='Fast Burn (1h)',
  datasource='$datasource',
  unit='short',
  decimals=1,
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: BURN_SLOW })
.addThreshold({ color: 'red', value: BURN_FAST })
.addTarget(prometheus.target(burnRateQuery('1h'), legendFormat='1h burn'))
+ { gridPos: { x: 4, y: 0, w: 4, h: 4 } };

local slowBurnStatPanel = statPanel.new(
  title='Slow Burn (6h)',
  datasource='$datasource',
  unit='short',
  decimals=1,
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 2.0 })
.addThreshold({ color: 'red', value: BURN_SLOW })
.addTarget(prometheus.target(burnRateQuery('6h'), legendFormat='6h burn'))
+ { gridPos: { x: 8, y: 0, w: 4, h: 4 } };

local latencyP99Panel = statPanel.new(
  title='p99 Latency (5m)',
  datasource='$datasource',
  unit='ms',
  decimals=0,
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: SLO_LATENCY_P99_MS * 0.8 })
.addThreshold({ color: 'red', value: SLO_LATENCY_P99_MS })
.addTarget(prometheus.target(latencyQuery('0.99', '5m'), legendFormat='p99'))
+ { gridPos: { x: 12, y: 0, w: 4, h: 4 } };

local podAvailPanel = statPanel.new(
  title='Pod Availability',
  datasource='$datasource',
  unit='percentunit',
  decimals=2,
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'red', value: null })
.addThreshold({ color: 'red', value: 0 })
.addThreshold({ color: 'yellow', value: 0.9 })
.addThreshold({ color: 'green', value: 0.99 })
.addTarget(prometheus.target(
  |||
    sum(kube_deployment_status_replicas_available{
      cluster=~"$cluster",
      namespace=~"$namespace",
      deployment=~"$workload"
    })
    /
    sum(kube_deployment_spec_replicas{
      cluster=~"$cluster",
      namespace=~"$namespace",
      deployment=~"$workload"
    })
  |||,
  legendFormat='Availability',
))
+ { gridPos: { x: 16, y: 0, w: 4, h: 4 } };

local oomKillsPanel = statPanel.new(
  title='OOM Kills (1h)',
  datasource='$datasource',
  unit='short',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'red', value: 1 })
.addTarget(prometheus.target(
  |||
    sum(
      increase(kube_pod_container_status_last_terminated_reason{
        cluster=~"$cluster",
        namespace=~"$namespace",
        reason="OOMKilled"
      }[1h])
    ) or vector(0)
  |||,
  legendFormat='OOM Kills',
  instant=true,
))
+ { gridPos: { x: 20, y: 0, w: 4, h: 4 } };

// ─── Row 2: Burn Rate Timeseries ─────────────────────────────────────────────

local burnRateTimeseriesPanel = graphPanel.new(
  title='Error Budget Burn Rate — Multi-Window',
  datasource='$datasource',
  fill=1,
  linewidth=2,
  points=false,
  legend_show=true,
  legend_alignAsTable=true,
  legend_rightSide=true,
  legend_values=true,
  legend_current=true,
  legend_max=true,
)
.addSeriesOverride({ alias: '/.*1h.*/', color: '#FF5733', linewidth: 2 })
.addSeriesOverride({ alias: '/.*6h.*/', color: '#FFA500', linewidth: 2 })
.addSeriesOverride({ alias: '/.*30m.*/', color: '#FFD700', linewidth: 1, dashes: true })
.addSeriesOverride({ alias: 'Fast burn threshold', color: '#FF0000', linewidth: 1, dashes: true, fill: 0 })
.addSeriesOverride({ alias: 'Slow burn threshold', color: '#FF9830', linewidth: 1, dashes: true, fill: 0 })
.addTarget(prometheus.target(burnRateQuery('1h'), legendFormat='1h burn rate'))
.addTarget(prometheus.target(burnRateQuery('6h'), legendFormat='6h burn rate'))
.addTarget(prometheus.target(burnRateQuery('30m'), legendFormat='30m burn rate'))
.addTarget(prometheus.target('vector(%s)' % BURN_FAST, legendFormat='Fast burn threshold'))
.addTarget(prometheus.target('vector(%s)' % BURN_SLOW, legendFormat='Slow burn threshold'))
+ { gridPos: { x: 0, y: 5, w: 24, h: 9 } };

// ─── Row 3: Latency SLO ──────────────────────────────────────────────────────

local latencyTimeseriesPanel = graphPanel.new(
  title='Request Latency — p50 / p95 / p99 (5m window)',
  datasource='$datasource',
  fill=0,
  linewidth=2,
  points=false,
  format='ms',
  legend_show=true,
  legend_alignAsTable=true,
  legend_rightSide=true,
  legend_values=true,
  legend_current=true,
)
.addSeriesOverride({ alias: 'p50', color: '#73BF69', linewidth: 1 })
.addSeriesOverride({ alias: 'p95', color: '#FADE2A', linewidth: 2 })
.addSeriesOverride({ alias: 'p99', color: '#FF5733', linewidth: 2 })
.addSeriesOverride({ alias: 'p99 SLO threshold', color: '#FF0000', linewidth: 1, dashes: true, fill: 0 })
.addSeriesOverride({ alias: 'p95 SLO threshold', color: '#FF9830', linewidth: 1, dashes: true, fill: 0 })
.addTarget(prometheus.target(latencyQuery('0.50', '5m'), legendFormat='p50'))
.addTarget(prometheus.target(latencyQuery('0.95', '5m'), legendFormat='p95'))
.addTarget(prometheus.target(latencyQuery('0.99', '5m'), legendFormat='p99'))
.addTarget(prometheus.target('vector(%s)' % SLO_LATENCY_P99_MS, legendFormat='p99 SLO threshold'))
.addTarget(prometheus.target('vector(%s)' % SLO_LATENCY_P95_MS, legendFormat='p95 SLO threshold'))
+ { gridPos: { x: 0, y: 14, w: 24, h: 9 } };

// ─── Row 4: Pod Health ───────────────────────────────────────────────────────

local podRestartPanel = graphPanel.new(
  title='Container Restarts (5m rate)',
  datasource='$datasource',
  fill=1,
  linewidth=2,
  format='short',
  legend_show=true,
)
.addTarget(prometheus.target(
  |||
    sum by (pod, container) (
      increase(kube_pod_container_status_restarts_total{
        cluster=~"$cluster",
        namespace=~"$namespace"
      }[5m])
    ) > 0
  |||,
  legendFormat='{{pod}}/{{container}}',
))
+ { gridPos: { x: 0, y: 23, w: 8, h: 8 } };

local podStatusPanel = statPanel.new(
  title='Not-Ready Pods',
  datasource='$datasource',
  unit='short',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 1 })
.addThreshold({ color: 'red', value: 3 })
.addTarget(prometheus.target(
  |||
    sum(
      kube_pod_status_ready{
        cluster=~"$cluster",
        namespace=~"$namespace",
        condition="false"
      }
    ) or vector(0)
  |||,
  legendFormat='Not Ready',
  instant=true,
))
+ { gridPos: { x: 8, y: 23, w: 4, h: 4 } };

local pendingPodsPanel = statPanel.new(
  title='Pending Pods',
  datasource='$datasource',
  unit='short',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 1 })
.addThreshold({ color: 'red', value: 5 })
.addTarget(prometheus.target(
  |||
    sum(
      kube_pod_status_phase{
        cluster=~"$cluster",
        namespace=~"$namespace",
        phase="Pending"
      }
    ) or vector(0)
  |||,
  legendFormat='Pending',
  instant=true,
))
+ { gridPos: { x: 8, y: 27, w: 4, h: 4 } };

local failedPodsPanel = statPanel.new(
  title='Failed Pods (last 1h)',
  datasource='$datasource',
  unit='short',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'red', value: 1 })
.addTarget(prometheus.target(
  |||
    sum(
      increase(kube_pod_status_phase{
        cluster=~"$cluster",
        namespace=~"$namespace",
        phase="Failed"
      }[1h])
    ) or vector(0)
  |||,
  legendFormat='Failed',
  instant=true,
))
+ { gridPos: { x: 12, y: 23, w: 4, h: 4 } };

local hpaStatusPanel = graphPanel.new(
  title='HPA Replica Count — Desired vs Current vs Min vs Max',
  datasource='$datasource',
  fill=0,
  linewidth=2,
  format='short',
  legend_show=true,
  legend_alignAsTable=true,
  legend_rightSide=false,
)
.addSeriesOverride({ alias: '/.*desired.*/', color: '#5794F2', linewidth: 2 })
.addSeriesOverride({ alias: '/.*current.*/', color: '#73BF69', linewidth: 2 })
.addSeriesOverride({ alias: '/.*max.*/', color: '#FF5733', linewidth: 1, dashes: true })
.addSeriesOverride({ alias: '/.*min.*/', color: '#73BF69', linewidth: 1, dashes: true })
.addTarget(prometheus.target(
  'kube_horizontalpodautoscaler_status_desired_replicas{cluster=~"$cluster",namespace=~"$namespace",horizontalpodautoscaler=~"$workload"}',
  legendFormat='{{horizontalpodautoscaler}} desired',
))
.addTarget(prometheus.target(
  'kube_horizontalpodautoscaler_status_current_replicas{cluster=~"$cluster",namespace=~"$namespace",horizontalpodautoscaler=~"$workload"}',
  legendFormat='{{horizontalpodautoscaler}} current',
))
.addTarget(prometheus.target(
  'kube_horizontalpodautoscaler_spec_max_replicas{cluster=~"$cluster",namespace=~"$namespace",horizontalpodautoscaler=~"$workload"}',
  legendFormat='{{horizontalpodautoscaler}} max',
))
.addTarget(prometheus.target(
  'kube_horizontalpodautoscaler_spec_min_replicas{cluster=~"$cluster",namespace=~"$namespace",horizontalpodautoscaler=~"$workload"}',
  legendFormat='{{horizontalpodautoscaler}} min',
))
+ { gridPos: { x: 16, y: 23, w: 8, h: 8 } };

// ─── Row 5: Resource Pressure ────────────────────────────────────────────────

local cpuThrottlePanel = graphPanel.new(
  title='CPU Throttling % (by container)',
  datasource='$datasource',
  fill=1,
  linewidth=2,
  format='percent',
  legend_show=true,
  legend_rightSide=true,
)
.addTarget(prometheus.target(
  |||
    100 * sum by (pod, container) (
      increase(container_cpu_cfs_throttled_periods_total{
        cluster=~"$cluster",
        namespace=~"$namespace",
        container!=""
      }[5m])
    )
    /
    sum by (pod, container) (
      increase(container_cpu_cfs_periods_total{
        cluster=~"$cluster",
        namespace=~"$namespace",
        container!=""
      }[5m])
    )
  |||,
  legendFormat='{{pod}}/{{container}}',
))
+ { gridPos: { x: 0, y: 31, w: 12, h: 8 } };

local memoryUtilPanel = graphPanel.new(
  title='Memory Utilization % (working set / limit)',
  datasource='$datasource',
  fill=1,
  linewidth=2,
  format='percent',
  legend_show=true,
  legend_rightSide=true,
)
.addSeriesOverride({ alias: '/.*/', max: 100 })
.addTarget(prometheus.target(
  |||
    100 * sum by (pod, container) (
      container_memory_working_set_bytes{
        cluster=~"$cluster",
        namespace=~"$namespace",
        container!=""
      }
    )
    /
    sum by (pod, container) (
      kube_pod_container_resource_limits{
        cluster=~"$cluster",
        namespace=~"$namespace",
        resource="memory",
        container!=""
      }
    )
  |||,
  legendFormat='{{pod}}/{{container}}',
))
+ { gridPos: { x: 12, y: 31, w: 12, h: 8 } };

// ─── Row 6: Active Alerts ────────────────────────────────────────────────────

local sloAlertsPanel = statPanel.new(
  title='Active SLO Alerts',
  datasource='$datasource',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'red', value: 1 })
.addTarget(prometheus.target(
  |||
    count by (alertname) (
      ALERTS{
        alertname=~"SLO.*",
        alertstate="firing",
        namespace=~"$namespace"
      }
    ) or vector(0)
  |||,
  legendFormat='{{alertname}}',
  instant=true,
))
+ { gridPos: { x: 0, y: 39, w: 12, h: 5 } };

local k8sAlertsPanel = statPanel.new(
  title='Active Kubernetes Alerts',
  datasource='$datasource',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 1 })
.addThreshold({ color: 'red', value: 3 })
.addTarget(prometheus.target(
  |||
    count by (alertname) (
      ALERTS{
        alertname=~"Kube.*|Pod.*|Node.*",
        alertstate="firing",
        namespace=~"$namespace"
      }
    ) or vector(0)
  |||,
  legendFormat='{{alertname}}',
  instant=true,
))
+ { gridPos: { x: 12, y: 39, w: 12, h: 5 } };

// ─── Dashboard Assembly ───────────────────────────────────────────────────────

dashboard.new(
  title='Kubernetes SLO Dashboard',
  uid='k8s-slo-v2',
  description='SLO burn rates, pod health, resource pressure, and alert status for Kubernetes workloads',
  tags=['slo', 'kubernetes', 'reliability', 'platform'],
  timezone='browser',
  refresh='1m',
  time_from='now-3h',
  time_to='now',
  editable=true,
  schemaVersion=36,
  graphTooltip=1,
)
.addTemplate(datasourceVar)
.addTemplate(clusterVar)
.addTemplate(namespaceVar)
.addTemplate(workloadVar)
// Row 1: SLO Health Summary
.addPanel(row.new(title='SLO Health Summary'), { x: 0, y: 0, w: 24, h: 1 })
.addPanel(errorBudgetPanel, { x: 0, y: 1, w: 4, h: 4 })
.addPanel(fastBurnStatPanel, { x: 4, y: 1, w: 4, h: 4 })
.addPanel(slowBurnStatPanel, { x: 8, y: 1, w: 4, h: 4 })
.addPanel(latencyP99Panel, { x: 12, y: 1, w: 4, h: 4 })
.addPanel(podAvailPanel, { x: 16, y: 1, w: 4, h: 4 })
.addPanel(oomKillsPanel, { x: 20, y: 1, w: 4, h: 4 })
// Row 2: Burn Rate Timeseries
.addPanel(row.new(title='Error Budget Burn Rate'), { x: 0, y: 5, w: 24, h: 1 })
.addPanel(burnRateTimeseriesPanel, { x: 0, y: 6, w: 24, h: 9 })
// Row 3: Latency
.addPanel(row.new(title='Latency SLO'), { x: 0, y: 15, w: 24, h: 1 })
.addPanel(latencyTimeseriesPanel, { x: 0, y: 16, w: 24, h: 9 })
// Row 4: Pod Health
.addPanel(row.new(title='Pod Health'), { x: 0, y: 25, w: 24, h: 1 })
.addPanel(podRestartPanel, { x: 0, y: 26, w: 8, h: 8 })
.addPanel(podStatusPanel, { x: 8, y: 26, w: 4, h: 4 })
.addPanel(pendingPodsPanel, { x: 8, y: 30, w: 4, h: 4 })
.addPanel(failedPodsPanel, { x: 12, y: 26, w: 4, h: 4 })
.addPanel(hpaStatusPanel, { x: 16, y: 26, w: 8, h: 8 })
// Row 5: Resource Pressure
.addPanel(row.new(title='Resource Pressure'), { x: 0, y: 34, w: 24, h: 1 })
.addPanel(cpuThrottlePanel, { x: 0, y: 35, w: 12, h: 8 })
.addPanel(memoryUtilPanel, { x: 12, y: 35, w: 12, h: 8 })
// Row 6: Alert Status
.addPanel(row.new(title='Active Alerts'), { x: 0, y: 43, w: 24, h: 1 })
.addPanel(sloAlertsPanel, { x: 0, y: 44, w: 12, h: 5 })
.addPanel(k8sAlertsPanel, { x: 12, y: 44, w: 12, h: 5 })
