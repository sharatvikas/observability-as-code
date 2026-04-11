// kubernetes-slo.libsonnet — Grafonnet dashboard for Kubernetes SLO burn rates
// Generates a Grafana dashboard JSON via: jsonnet -J vendor kubernetes-slo.libsonnet
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local row = grafana.row;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local prometheus = grafana.target.prometheus;
local template = grafana.template;

local colors = {
  green: '#73BF69',
  yellow: '#FADE2A',
  orange: '#FF9830',
  red: '#F2495C',
};

// Thresholds for SLO burn rate panels
local burnRateThresholds = [
  { color: colors.green, value: null },
  { color: colors.yellow, value: 1 },
  { color: colors.orange, value: 6 },
  { color: colors.red, value: 14.4 },
];

local sloTarget = '0.999';  // 99.9% SLO

dashboard.new(
  'Kubernetes SLO Dashboard',
  uid='k8s-slo-v1',
  tags=['slo', 'kubernetes', 'reliability'],
  schemaVersion=36,
  refresh='1m',
  time_from='now-6h',
)
.addTemplate(
  template.datasource(
    'datasource',
    'prometheus',
    'Prometheus',
    hide='',
  )
)
.addTemplate(
  template.new(
    name='namespace',
    datasource='$datasource',
    query='label_values(up, namespace)',
    label='Namespace',
    refresh='time',
    multi=true,
    includeAll=true,
  )
)
.addTemplate(
  template.new(
    name='job',
    datasource='$datasource',
    query='label_values(up{namespace=~"$namespace"}, job)',
    label='Service',
    refresh='time',
    multi=false,
    includeAll=false,
  )
)
.addRow(
  row.new('Error Budget Status')
  .addPanel(
    statPanel.new(
      'Error Budget Remaining (30d)',
      datasource='$datasource',
      unit='percentunit',
      decimals=2,
      colorMode='background',
    )
    .addThresholds([
      { color: colors.red, value: null },
      { color: colors.orange, value: 0.1 },
      { color: colors.yellow, value: 0.25 },
      { color: colors.green, value: 0.5 },
    ])
    .addTarget(
      prometheus.target(
        'slo:error_budget_remaining:ratio{job="$job"}',
        legendFormat='Error Budget',
      )
    )
    { gridPos: { h: 4, w: 6, x: 0, y: 0 } }
  )
  .addPanel(
    statPanel.new(
      'Fast Burn Rate (1h window)',
      datasource='$datasource',
      unit='short',
      decimals=1,
    )
    .addThresholds(burnRateThresholds)
    .addTarget(
      prometheus.target(
        |||
          sum(rate(http_requests_total{status=~"5..",job="$job"}[1h]))
          /
          sum(rate(http_requests_total{job="$job"}[1h]))
          / (1 - %(slo)s)
        ||| % { slo: sloTarget },
        legendFormat='Burn Rate 1h',
      )
    )
    { gridPos: { h: 4, w: 6, x: 6, y: 0 } }
  )
  .addPanel(
    statPanel.new(
      'Slow Burn Rate (6h window)',
      datasource='$datasource',
      unit='short',
      decimals=1,
    )
    .addThresholds(burnRateThresholds)
    .addTarget(
      prometheus.target(
        |||
          sum(rate(http_requests_total{status=~"5..",job="$job"}[6h]))
          /
          sum(rate(http_requests_total{job="$job"}[6h]))
          / (1 - %(slo)s)
        ||| % { slo: sloTarget },
        legendFormat='Burn Rate 6h',
      )
    )
    { gridPos: { h: 4, w: 6, x: 12, y: 0 } }
  )
)
.addRow(
  row.new('Request Rates & Errors')
  .addPanel(
    graphPanel.new(
      'Request Rate',
      datasource='$datasource',
      format='reqps',
      legend_show=true,
      legend_rightSide=false,
      fill=1,
      linewidth=2,
    )
    .addTarget(
      prometheus.target(
        'sum(rate(http_requests_total{job="$job"}[5m])) by (status)',
        legendFormat='{{status}}',
      )
    )
    { gridPos: { h: 8, w: 12, x: 0, y: 8 } }
  )
  .addPanel(
    graphPanel.new(
      'Error Rate %',
      datasource='$datasource',
      format='percent',
      legend_show=true,
      fill=1,
      linewidth=2,
      thresholds=[
        { colorMode: 'critical', fill: true, line: true, op: 'gt', value: 0.1 },
      ],
    )
    .addTarget(
      prometheus.target(
        |||
          sum(rate(http_requests_total{status=~"5..",job="$job"}[5m]))
          /
          sum(rate(http_requests_total{job="$job"}[5m])) * 100
        |||,
        legendFormat='Error Rate',
      )
    )
    { gridPos: { h: 8, w: 12, x: 12, y: 8 } }
  )
)
.addRow(
  row.new('Latency SLOs (p50 / p95 / p99)')
  .addPanel(
    graphPanel.new(
      'Request Latency Percentiles',
      datasource='$datasource',
      format='s',
      legend_show=true,
      fill=0,
      linewidth=2,
    )
    .addTarget(
      prometheus.target(
        'histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{job="$job"}[5m])) by (le))',
        legendFormat='p50',
      )
    )
    .addTarget(
      prometheus.target(
        'histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="$job"}[5m])) by (le))',
        legendFormat='p95',
      )
    )
    .addTarget(
      prometheus.target(
        'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="$job"}[5m])) by (le))',
        legendFormat='p99',
      )
    )
    { gridPos: { h: 8, w: 24, x: 0, y: 20 } }
  )
)
