// SLO Overview Dashboard — Multi-window burn rate monitoring
//
// Displays SLO error budget status for all tracked services using the
// multi-window, multi-burn-rate approach from the Google SRE Workbook.
//
// Panels:
//   Row 1: Error Budget Overview (stat panels — % remaining per service)
//   Row 2: Burn Rate — Fast (1h window) and Slow (6h window) indicators
//   Row 3: Error Rate timeseries (5m, 30m, 1h, 6h windows overlaid)
//   Row 4: Latency SLO — % requests above threshold
//   Row 5: Error Budget Burn Rate heatmap (30-day view)
//
// Usage:
//   jsonnet -J vendor dashboards/slo-overview.libsonnet > /tmp/slo-overview.json
//   grafana-dash import /tmp/slo-overview.json
//
// Requires:
//   - Prometheus recording rules from recording-rules/slo.yaml
//   - Alerting rules from alerts/slo.yaml

local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local gaugePanel = grafana.gaugePanel;
local row = grafana.row;
local template = grafana.template;
local prometheus = grafana.target.prometheus;

// ─── Variable Templates ──────────────────────────────────────────────────────

local serviceVar = template.new(
  name='service',
  label='Service',
  datasource='Prometheus',
  query='label_values(job:request_error_rate:ratio_rate5m, job)',
  multi=true,
  includeAll=true,
  allValues='payments-api|checkout-api|auth-api',
  refresh=2,
);

// SLO targets (can be overridden per-service in a real implementation)
local SLO_AVAILABILITY = 0.999;  // 99.9%
local SLO_LATENCY = 0.95;        // 95th percentile

// Error budget = 1 - SLO
local ERROR_BUDGET_30D_MINUTES = (1 - SLO_AVAILABILITY) * 30 * 24 * 60;  // 43.2 minutes

// ─── Helper Functions ────────────────────────────────────────────────────────

local burnRateQuery(window) =
  'job:request_error_rate:ratio_rate%(w)s{job=~"$service"}' % { w: window };

local latencyBurnQuery(window) =
  'job:request_latency_above_slo:ratio_rate%(w)s{job=~"$service"}' % { w: window };

// ─── Row 1: Error Budget Overview ─────────────────────────────────────────────

local budgetRemainingPanel = statPanel.new(
  title='Error Budget Remaining (30d)',
  datasource='Prometheus',
  unit='percent',
  reducerFunction='last',
  colorMode='background',
  graphMode='none',
  justifyMode='center',
)
.addThreshold({ color: 'red', value: null })
.addThreshold({ color: 'red', value: 0 })
.addThreshold({ color: 'yellow', value: 25 })
.addThreshold({ color: 'green', value: 50 })
.addTarget(prometheus.target(
  |||
    (
      1 - (
        sum by (job) (increase(job:request_error_rate:ratio_rate5m{job=~"$service"}[30d]))
        / %(budget)s
      )
    ) * 100
  ||| % { budget: ERROR_BUDGET_30D_MINUTES },
  legendFormat='{{job}}',
))
+ { gridPos: { x: 0, y: 0, w: 8, h: 8 } };

local fastBurnPanel = statPanel.new(
  title='Fast Burn Rate (1h window)',
  datasource='Prometheus',
  unit='short',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 6 })    // 6x = slow burn threshold
.addThreshold({ color: 'red', value: 14.4 })     // 14.4x = fast burn threshold
.addTarget(prometheus.target(
  'job:request_error_rate:ratio_rate1h{job=~"$service"} / %(slo_err)s' % { slo_err: 1 - SLO_AVAILABILITY },
  legendFormat='{{job}} burn rate',
))
+ { gridPos: { x: 8, y: 0, w: 8, h: 8 } };

local latencyBudgetPanel = statPanel.new(
  title='Latency SLO Compliance (5m)',
  datasource='Prometheus',
  unit='percentunit',
  reducerFunction='last',
  colorMode='background',
)
.addThreshold({ color: 'red', value: null })
.addThreshold({ color: 'red', value: 0 })
.addThreshold({ color: 'yellow', value: 0.93 })
.addThreshold({ color: 'green', value: 0.95 })
.addTarget(prometheus.target(
  '1 - job:request_latency_above_slo:ratio_rate5m{job=~"$service"}',
  legendFormat='{{job}} latency SLO',
))
+ { gridPos: { x: 16, y: 0, w: 8, h: 8 } };

// ─── Row 2: Burn Rate Timeseries ──────────────────────────────────────────────

local burnRateTimeseriesPanel = graphPanel.new(
  title='Error Budget Burn Rate (multi-window)',
  datasource='Prometheus',
  fill=1,
  linewidth=2,
  points=false,
  legend_show=true,
  legend_alignAsTable=true,
  legend_rightSide=true,
)
.addSeriesOverride({ alias: '1h burn rate', color: '#FF5733', linewidth: 2 })
.addSeriesOverride({ alias: '6h burn rate', color: '#FFA500', linewidth: 2 })
.addSeriesOverride({ alias: '30m burn rate', color: '#FFD700', linewidth: 1, dashes: true })
.addTarget(prometheus.target(burnRateQuery('1h'), legendFormat='{{job}} — 1h burn rate'))
.addTarget(prometheus.target(burnRateQuery('6h'), legendFormat='{{job}} — 6h burn rate'))
.addTarget(prometheus.target(burnRateQuery('30m'), legendFormat='{{job}} — 30m burn rate'))
// Threshold lines
.addTarget(prometheus.target(
  'vector(14.4)', legendFormat='Fast burn threshold (14.4x)',
))
.addTarget(prometheus.target(
  'vector(6)', legendFormat='Slow burn threshold (6x)',
))
+ { gridPos: { x: 0, y: 8, w: 24, h: 10 } };

// ─── Row 3: Error Rate Windows ────────────────────────────────────────────────

local errorRatePanel = graphPanel.new(
  title='Error Rate — Multi-Window',
  datasource='Prometheus',
  fill=1,
  percentage=true,
  lines=true,
  points=false,
)
.addTarget(prometheus.target(
  burnRateQuery('5m') + ' * 100',
  legendFormat='{{job}} — 5m (instant)',
))
.addTarget(prometheus.target(
  burnRateQuery('30m') + ' * 100',
  legendFormat='{{job}} — 30m',
))
.addTarget(prometheus.target(
  burnRateQuery('1h') + ' * 100',
  legendFormat='{{job}} — 1h',
))
.addTarget(prometheus.target(
  burnRateQuery('6h') + ' * 100',
  legendFormat='{{job}} — 6h',
))
// SLO violation line at (1 - SLO) * 100
.addTarget(prometheus.target(
  'vector(%(threshold)s)' % { threshold: (1 - SLO_AVAILABILITY) * 100 },
  legendFormat='SLO threshold (%(pct)s%%)' % { pct: (1 - SLO_AVAILABILITY) * 100 },
))
+ { gridPos: { x: 0, y: 18, w: 12, h: 10 } };

// ─── Row 4: Latency SLO ───────────────────────────────────────────────────────

local latencyPanel = graphPanel.new(
  title='Latency SLO Compliance — % Requests Above Threshold',
  datasource='Prometheus',
  fill=1,
  percentage=true,
)
.addTarget(prometheus.target(
  latencyBurnQuery('5m') + ' * 100',
  legendFormat='{{job}} — 5m (instant)',
))
.addTarget(prometheus.target(
  latencyBurnQuery('30m') + ' * 100',
  legendFormat='{{job}} — 30m',
))
.addTarget(prometheus.target(
  latencyBurnQuery('1h') + ' * 100',
  legendFormat='{{job}} — 1h',
))
.addTarget(prometheus.target(
  latencyBurnQuery('6h') + ' * 100',
  legendFormat='{{job}} — 6h',
))
.addTarget(prometheus.target(
  'vector(%(threshold)s)' % { threshold: (1 - SLO_LATENCY) * 100 },
  legendFormat='Latency SLO threshold (%(pct)s%%)' % { pct: (1 - SLO_LATENCY) * 100 },
))
+ { gridPos: { x: 12, y: 18, w: 12, h: 10 } };

// ─── Row 5: Alert Status ──────────────────────────────────────────────────────

local alertStatusPanel = statPanel.new(
  title='Active SLO Alerts',
  datasource='Prometheus',
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
        job=~"$service"
      }
    ) or vector(0)
  |||,
  legendFormat='{{alertname}}',
  instant=true,
))
+ { gridPos: { x: 0, y: 28, w: 12, h: 6 } };

local errorBudgetConsumedPanel = gaugePanel.new(
  title='Error Budget Consumed (30d)',
  datasource='Prometheus',
  unit='percent',
  min=0,
  max=100,
)
.addThreshold({ color: 'green', value: null })
.addThreshold({ color: 'green', value: 0 })
.addThreshold({ color: 'yellow', value: 50 })
.addThreshold({ color: 'orange', value: 75 })
.addThreshold({ color: 'red', value: 90 })
.addTarget(prometheus.target(
  |||
    clamp_max(
      sum by (job) (
        increase(job:request_error_rate:ratio_rate5m{job=~"$service"}[30d])
      )
      / %(budget)s * 100,
      100
    )
  ||| % { budget: ERROR_BUDGET_30D_MINUTES },
  legendFormat='{{job}}',
  instant=true,
))
+ { gridPos: { x: 12, y: 28, w: 12, h: 6 } };

// ─── Dashboard Assembly ───────────────────────────────────────────────────────

dashboard.new(
  title='SLO Overview',
  uid='slo-overview',
  description='Multi-window burn rate SLO dashboard for all tracked services',
  tags=['slo', 'error-budget', 'reliability'],
  timezone='browser',
  refresh='30s',
  time_from='now-6h',
  time_to='now',
  editable=true,
  schemaVersion=36,
  graphTooltip=1,   // Shared crosshair
)
.addTemplate(serviceVar)
.addPanel(row.new(title='Error Budget Overview'), { x: 0, y: 0, w: 24, h: 1 })
.addPanel(budgetRemainingPanel, { x: 0, y: 1, w: 8, h: 8 })
.addPanel(fastBurnPanel, { x: 8, y: 1, w: 8, h: 8 })
.addPanel(latencyBudgetPanel, { x: 16, y: 1, w: 8, h: 8 })
.addPanel(row.new(title='Burn Rate Timeseries'), { x: 0, y: 9, w: 24, h: 1 })
.addPanel(burnRateTimeseriesPanel, { x: 0, y: 10, w: 24, h: 10 })
.addPanel(row.new(title='Error Rate and Latency SLO'), { x: 0, y: 20, w: 24, h: 1 })
.addPanel(errorRatePanel, { x: 0, y: 21, w: 12, h: 10 })
.addPanel(latencyPanel, { x: 12, y: 21, w: 12, h: 10 })
.addPanel(row.new(title='Budget Consumption and Alerts'), { x: 0, y: 31, w: 24, h: 1 })
.addPanel(alertStatusPanel, { x: 0, y: 32, w: 12, h: 6 })
.addPanel(errorBudgetConsumedPanel, { x: 12, y: 32, w: 12, h: 6 })
