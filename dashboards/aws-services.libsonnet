// AWS Services Dashboard — ALB, RDS, and SQS observability panels via CloudWatch metrics
// Rendered with Grafonnet and deployed via CI to a Grafana instance.
//
// Usage:
//   jsonnet -J vendor dashboards/aws-services.libsonnet > /tmp/aws-services.json
//   grafana-dash import /tmp/aws-services.json

local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local graphPanel = grafana.graphPanel;
local statPanel = grafana.statPanel;
local row = grafana.row;
local template = grafana.template;
local cloudwatch = grafana.target.cloudwatch;

// ─── Variable Templates ──────────────────────────────────────────────────────

local regionVar = template.new(
  name='region',
  label='AWS Region',
  datasource='$datasource',
  query='regions()',
  current='us-east-1',
  refresh=1,
);

local albVar = template.new(
  name='alb',
  label='Load Balancer',
  datasource='$datasource',
  query='dimension_values($region,AWS/ApplicationELB,RequestCount,LoadBalancer)',
  refresh=2,
  multi=true,
  includeAll=true,
);

local targetGroupVar = template.new(
  name='target_group',
  label='Target Group',
  datasource='$datasource',
  query='dimension_values($region,AWS/ApplicationELB,RequestCount,TargetGroup)',
  refresh=2,
  multi=true,
  includeAll=true,
);

local rdsVar = template.new(
  name='db_instance',
  label='RDS Instance',
  datasource='$datasource',
  query='dimension_values($region,AWS/RDS,CPUUtilization,DBInstanceIdentifier)',
  refresh=2,
  multi=true,
  includeAll=true,
);

local sqsVar = template.new(
  name='queue',
  label='SQS Queue',
  datasource='$datasource',
  query='dimension_values($region,AWS/SQS,NumberOfMessagesSent,QueueName)',
  refresh=2,
  multi=true,
  includeAll=true,
);

// ─── ALB Panels ──────────────────────────────────────────────────────────────

local albRequestRatePanel = graphPanel.new(
  title='ALB — Request Rate (req/s)',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  legend_show=true,
  legend_alignAsTable=true,
  legend_rightSide=true,
  legend_values=true,
  legend_current=true,
  legend_avg=true,
  yaxes=[
    { format: 'reqps', label: 'req/s', min: 0 },
    { format: 'short', show: false },
  ],
).addTarget(
  cloudwatch.new(
    alias='{{LoadBalancer}} requests',
    dimensions={ LoadBalancer: '$alb' },
    expression='',
    highResolution=false,
    id='',
    matchExact=true,
    metricName='RequestCount',
    namespace='AWS/ApplicationELB',
    period='60',
    refId='A',
    region='$region',
    statistics=['Sum'],
  )
);

local albLatencyPanel = graphPanel.new(
  title='ALB — Response Latency (p50 / p95 / p99)',
  datasource='$datasource',
  linewidth=2,
  fill=0,
  yaxes=[
    { format: 's', label: 'Latency', min: 0 },
    { format: 'short', show: false },
  ],
).addTargets([
  cloudwatch.new(
    alias='p50',
    dimensions={ LoadBalancer: '$alb' },
    metricName='TargetResponseTime',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['p50'],
    refId='A',
  ),
  cloudwatch.new(
    alias='p95',
    dimensions={ LoadBalancer: '$alb' },
    metricName='TargetResponseTime',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['p95'],
    refId='B',
  ),
  cloudwatch.new(
    alias='p99',
    dimensions={ LoadBalancer: '$alb' },
    metricName='TargetResponseTime',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['p99'],
    refId='C',
  ),
]);

local albErrorRatePanel = graphPanel.new(
  title='ALB — 4xx / 5xx Error Rate',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 'percent', label: 'Error %', min: 0, max: 100 },
    { format: 'short', show: false },
  ],
).addTargets([
  cloudwatch.new(
    alias='4xx %',
    expression='(HTTPCode_Target_4XX_Count / RequestCount) * 100',
    id='e1',
    metricName='',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  ),
  cloudwatch.new(
    alias='5xx %',
    expression='(HTTPCode_Target_5XX_Count / RequestCount) * 100',
    id='e2',
    metricName='',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='B',
  ),
]);

local albHealthyHostsPanel = statPanel.new(
  title='ALB — Healthy Hosts',
  datasource='$datasource',
  reducerFunction='lastNotNull',
  colorMode='background',
  graphMode='area',
  justifyMode='center',
).addThresholds([
  { color: 'red', value: 0 },
  { color: 'orange', value: 1 },
  { color: 'green', value: 2 },
]).addTarget(
  cloudwatch.new(
    alias='Healthy Hosts',
    dimensions={ LoadBalancer: '$alb', TargetGroup: '$target_group' },
    metricName='HealthyHostCount',
    namespace='AWS/ApplicationELB',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
);

// ─── RDS Panels ──────────────────────────────────────────────────────────────

local rdsCpuPanel = graphPanel.new(
  title='RDS — CPU Utilization',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 'percent', label: 'CPU %', min: 0, max: 100 },
    { format: 'short', show: false },
  ],
).addTarget(
  cloudwatch.new(
    alias='{{DBInstanceIdentifier}} CPU',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='CPUUtilization',
    namespace='AWS/RDS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
).addSeriesOverride({ alias: '/.*/', thresholds: [80] });

local rdsConnectionsPanel = graphPanel.new(
  title='RDS — Database Connections',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 'short', label: 'Connections', min: 0 },
    { format: 'short', show: false },
  ],
).addTarget(
  cloudwatch.new(
    alias='{{DBInstanceIdentifier}}',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='DatabaseConnections',
    namespace='AWS/RDS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
);

local rdsIOPSPanel = graphPanel.new(
  title='RDS — Read / Write IOPS',
  datasource='$datasource',
  linewidth=2,
  fill=0,
  yaxes=[
    { format: 'iops', label: 'IOPS', min: 0 },
    { format: 'short', show: false },
  ],
).addTargets([
  cloudwatch.new(
    alias='Read IOPS',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='ReadIOPS',
    namespace='AWS/RDS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  ),
  cloudwatch.new(
    alias='Write IOPS',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='WriteIOPS',
    namespace='AWS/RDS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='B',
  ),
]);

local rdsFreeStoragePanel = statPanel.new(
  title='RDS — Free Storage',
  datasource='$datasource',
  reducerFunction='lastNotNull',
  colorMode='background',
  unit='bytes',
).addThresholds([
  { color: 'red', value: 0 },
  { color: 'orange', value: 5368709120 },   // 5 GiB
  { color: 'green', value: 21474836480 },   // 20 GiB
]).addTarget(
  cloudwatch.new(
    alias='Free Storage',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='FreeStorageSpace',
    namespace='AWS/RDS',
    period='300',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
);

local rdsReplicationLagPanel = graphPanel.new(
  title='RDS — Replica Lag',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 's', label: 'Lag', min: 0 },
    { format: 'short', show: false },
  ],
).addTarget(
  cloudwatch.new(
    alias='{{DBInstanceIdentifier}} replica lag',
    dimensions={ DBInstanceIdentifier: '$db_instance' },
    metricName='ReplicaLag',
    namespace='AWS/RDS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
);

// ─── SQS Panels ──────────────────────────────────────────────────────────────

local sqsThroughputPanel = graphPanel.new(
  title='SQS — Message Throughput',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 'short', label: 'Messages / min', min: 0 },
    { format: 'short', show: false },
  ],
).addTargets([
  cloudwatch.new(
    alias='{{QueueName}} sent',
    dimensions={ QueueName: '$queue' },
    metricName='NumberOfMessagesSent',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Sum'],
    refId='A',
  ),
  cloudwatch.new(
    alias='{{QueueName}} received',
    dimensions={ QueueName: '$queue' },
    metricName='NumberOfMessagesReceived',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Sum'],
    refId='B',
  ),
  cloudwatch.new(
    alias='{{QueueName}} deleted',
    dimensions={ QueueName: '$queue' },
    metricName='NumberOfMessagesDeleted',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Sum'],
    refId='C',
  ),
]);

local sqsDepthPanel = statPanel.new(
  title='SQS — Messages Visible (Queue Depth)',
  datasource='$datasource',
  reducerFunction='lastNotNull',
  colorMode='background',
  graphMode='area',
).addThresholds([
  { color: 'green', value: 0 },
  { color: 'orange', value: 1000 },
  { color: 'red', value: 10000 },
]).addTarget(
  cloudwatch.new(
    alias='{{QueueName}}',
    dimensions={ QueueName: '$queue' },
    metricName='ApproximateNumberOfMessagesVisible',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Average'],
    refId='A',
  )
);

local sqsAgePanel = graphPanel.new(
  title='SQS — Oldest Message Age',
  datasource='$datasource',
  linewidth=2,
  fill=1,
  yaxes=[
    { format: 's', label: 'Age', min: 0 },
    { format: 'short', show: false },
  ],
).addTarget(
  cloudwatch.new(
    alias='{{QueueName}} oldest msg age',
    dimensions={ QueueName: '$queue' },
    metricName='ApproximateAgeOfOldestMessage',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Maximum'],
    refId='A',
  )
);

local sqsDLQDepthPanel = statPanel.new(
  title='SQS — Dead Letter Queue Depth',
  datasource='$datasource',
  reducerFunction='lastNotNull',
  colorMode='background',
).addThresholds([
  { color: 'green', value: 0 },
  { color: 'red', value: 1 },
]).addTarget(
  cloudwatch.new(
    alias='DLQ depth',
    dimensions={ QueueName: '$queue' },
    metricName='ApproximateNumberOfMessagesVisible',
    namespace='AWS/SQS',
    period='60',
    region='$region',
    statistics=['Sum'],
    refId='A',
  )
);

// ─── Dashboard Assembly ───────────────────────────────────────────────────────

dashboard.new(
  'AWS Services — ALB / RDS / SQS',
  schemaVersion=30,
  tags=['aws', 'alb', 'rds', 'sqs', 'infrastructure'],
  timezone='browser',
  time_from='now-3h',
  time_to='now',
  refresh='1m',
  uid='aws-services-overview',
  editable=true,
)
.addTemplate(template.datasource(
  name='datasource',
  query='cloudwatch',
  label='CloudWatch Data Source',
  current='CloudWatch',
))
.addTemplate(regionVar)
.addTemplate(albVar)
.addTemplate(targetGroupVar)
.addTemplate(rdsVar)
.addTemplate(sqsVar)

// ── ALB Row ────────────────────────────────────────────────────────────────
.addRow(
  row.new(title='Application Load Balancer', collapse=false)
  .addPanel(albRequestRatePanel, gridPos={ x: 0, y: 1, w: 12, h: 8 })
  .addPanel(albLatencyPanel,     gridPos={ x: 12, y: 1, w: 12, h: 8 })
  .addPanel(albErrorRatePanel,   gridPos={ x: 0, y: 9, w: 16, h: 8 })
  .addPanel(albHealthyHostsPanel, gridPos={ x: 16, y: 9, w: 8, h: 8 })
)

// ── RDS Row ────────────────────────────────────────────────────────────────
.addRow(
  row.new(title='RDS / Aurora', collapse=false)
  .addPanel(rdsCpuPanel,           gridPos={ x: 0, y: 17, w: 12, h: 8 })
  .addPanel(rdsConnectionsPanel,   gridPos={ x: 12, y: 17, w: 12, h: 8 })
  .addPanel(rdsIOPSPanel,          gridPos={ x: 0, y: 25, w: 12, h: 8 })
  .addPanel(rdsFreeStoragePanel,   gridPos={ x: 12, y: 25, w: 6, h: 8 })
  .addPanel(rdsReplicationLagPanel, gridPos={ x: 18, y: 25, w: 6, h: 8 })
)

// ── SQS Row ────────────────────────────────────────────────────────────────
.addRow(
  row.new(title='SQS Queues', collapse=false)
  .addPanel(sqsThroughputPanel, gridPos={ x: 0, y: 33, w: 12, h: 8 })
  .addPanel(sqsDepthPanel,      gridPos={ x: 12, y: 33, w: 6, h: 8 })
  .addPanel(sqsAgePanel,        gridPos={ x: 0, y: 41, w: 12, h: 8 })
  .addPanel(sqsDLQDepthPanel,   gridPos={ x: 12, y: 41, w: 6, h: 8 })
)
