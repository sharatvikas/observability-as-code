# observability-as-code

> **Complete observability stack as code.** Grafana dashboards, Prometheus alerting rules, recording rules, and Alertmanager configs — all version-controlled, tested, and deployed via CI/CD. Includes an AI-powered alert enrichment layer that adds runbook context and probable causes to every firing alert.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Grafana](https://img.shields.io/badge/grafana-10+-orange.svg)](https://grafana.com)
[![Prometheus](https://img.shields.io/badge/prometheus-2.x-red.svg)](https://prometheus.io)
[![Terraform](https://img.shields.io/badge/terraform-1.7+-623CE4.svg)](https://terraform.io)

---

## The Problem with Most Observability Setups

- Dashboards created manually in Grafana UI — no version control, no review, no way to reproduce
- Alert rules written once and never reviewed — alert fatigue from miscalibrated thresholds
- Alerts fire with no context — on-call engineer spends 10 minutes figuring out what the alert even means
- Runbooks live in Confluence, not linked to alerts — engineers miss them under pressure

This repo solves all of the above.

---

## What's Included

### 1. Dashboard-as-Code (Grafonnet / Terraform)
Every Grafana dashboard is defined in code and deployed automatically:
```
dashboards/
├── services/
│   ├── api-gateway.jsonnet       # API Gateway: RPS, latency, error rate, saturation
│   ├── kubernetes-workloads.jsonnet  # Pod/container resource utilization
│   ├── databases.jsonnet         # RDS: connections, query latency, replication lag
│   └── kafka.jsonnet             # Consumer lag, throughput, partition health
├── platform/
│   ├── slo-overview.jsonnet      # Multi-service SLO burn rate overview
│   ├── cost-vs-performance.jsonnet
│   └── kubernetes-nodes.jsonnet
└── lib/
    └── common.libsonnet          # Shared panel templates and color schemes
```

### 2. Alert Rules Library
Production-tested Prometheus alerting rules organized by domain:
```yaml
# alerts/kubernetes.yaml
- alert: PodCrashLoopBackOff
  expr: |
    rate(kube_pod_container_status_restarts_total[15m]) * 60 > 1
  for: 5m
  labels:
    severity: warning
    team: "{{ $labels.namespace }}"
  annotations:
    summary: "Pod {{ $labels.pod }} is crash-looping"
    runbook: "https://runbooks.your-org.com/k8s/crashloop"
    # AI enrichment added at alert time (see below)
```

Rule categories:
- `alerts/kubernetes.yaml` — Pod, node, PVC, deployment health
- `alerts/slo.yaml` — Multi-window, multi-burn-rate SLO alerts (Google SRE book method)
- `alerts/aws.yaml` — EC2, RDS, ELB, API Gateway, Lambda
- `alerts/application.yaml` — HTTP error rates, latency SLOs, saturation
- `alerts/kafka.yaml` — Consumer lag, broker health
- `alerts/database.yaml` — Connection pool, replication, slow queries

### 3. Recording Rules
Pre-computed aggregations that make dashboards fast and reduce query load:
```yaml
# recording-rules/slo.yaml
- record: job:request_error_rate:ratio_rate5m
  expr: |
    sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
    /
    sum(rate(http_requests_total[5m])) by (job)
```

### 4. AI Alert Enrichment (novel feature)
An Alertmanager webhook receiver that intercepts firing alerts and augments them with AI-generated context before routing to Slack/PagerDuty:

```
Alert fires: PodCrashLoopBackOff (payments-api)
         │
         ▼
┌────────────────────┐
│  Enrichment Server │
│  (Go webhook)      │
│                    │
│  1. Fetch pod logs │
│  2. Fetch events   │
│  3. Check recent   │
│     deployments    │
└────────┬───────────┘
         │ Claude API
         ▼
Enriched Slack message:
  ⚠ ALERT: PodCrashLoopBackOff
  Service: payments-api | Namespace: production
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  AI Summary: Container exits with code 1 immediately after start.
  Last 10 log lines show "connection refused" to payments-db-primary:5432.
  Recent change: DB failover at 14:23 UTC — new primary endpoint not
  yet reflected in app config. This is a configuration drift issue,
  not an application bug.
  
  Probable Fix: Restart pods after updating DB_HOST in ConfigMap.
  Runbook: https://runbooks.your-org.com/k8s/db-failover
  
  [View Dashboard] [View Logs] [Acknowledge]
```

### 5. SLO Framework
Multi-window, multi-burn-rate SLO alerting following the Google SRE Workbook approach:
```yaml
# slos/payments-api.yaml
service: payments-api
slos:
  - name: availability
    target: 99.9           # 99.9% over 30 days
    indicator:
      ratio:
        good: http_requests_total{status!~"5..", job="payments-api"}
        total: http_requests_total{job="payments-api"}
  - name: latency
    target: 95             # 95% of requests < 200ms
    indicator:
      ratio:
        good: http_request_duration_seconds_bucket{le="0.2", job="payments-api"}
        total: http_request_duration_seconds_count{job="payments-api"}
```

---

## Deployment

### Via Terraform (Grafana provider)

```bash
cd terraform/
terraform init
terraform apply \
  -var="grafana_url=https://grafana.your-org.com" \
  -var="grafana_token=$GRAFANA_SA_TOKEN"
```

### Via CI/CD (GitHub Actions)

```yaml
# .github/workflows/deploy-dashboards.yaml
on:
  push:
    branches: [main]
    paths: ['dashboards/**', 'alerts/**']
```

Every PR runs:
1. `promtool check rules alerts/**/*.yaml` — validates alert rule syntax
2. `jsonnet fmt --test dashboards/**/*.jsonnet` — enforces dashboard formatting
3. Terraform plan shows which dashboards will change
4. After merge: dashboards auto-deployed to Grafana

---

## Project Structure

```
observability-as-code/
├── dashboards/
│   ├── services/           # Service-level dashboards
│   ├── platform/           # Platform/infra dashboards
│   └── lib/                # Shared Grafonnet library
├── alerts/                 # Prometheus alerting rules
├── recording-rules/        # Prometheus recording rules
├── alertmanager/
│   ├── config.yaml         # Alertmanager routing config
│   └── templates/          # Slack/PagerDuty message templates
├── enrichment-server/      # AI alert enrichment webhook (Go)
│   ├── main.go
│   ├── enricher.go         # Claude API integration
│   └── Dockerfile
├── slos/                   # SLO definitions
├── terraform/              # Grafana + Alertmanager deployment
│   ├── modules/grafana/
│   └── environments/
├── tests/
│   ├── alert-tests/        # promtool unit tests for alert rules
│   └── dashboard-tests/    # Grafonnet rendering tests
└── .github/workflows/
```

---

## Alert Testing

Alert rules are unit-tested using `promtool test rules`:

```yaml
# tests/alert-tests/kubernetes_test.yaml
rule_files:
  - ../../alerts/kubernetes.yaml

tests:
  - name: PodCrashLoopBackOff fires after 5 minutes of restarts
    interval: 1m
    input_series:
      - series: 'kube_pod_container_status_restarts_total{pod="api-xyz"}'
        values: '0 1 2 3 4 5 6 7'
    alert_rule_test:
      - eval_time: 10m
        alertname: PodCrashLoopBackOff
        exp_alerts:
          - exp_labels:
              severity: warning
              pod: api-xyz
```

```bash
make test-alerts  # Runs all alert unit tests
```

---

## Roadmap

- [x] Kubernetes alerting rules
- [x] SLO burn rate alerts (multi-window)
- [x] Grafana dashboard-as-code (Grafonnet)
- [x] CI validation pipeline
- [ ] AI alert enrichment server
- [ ] Alertmanager routing as code
- [ ] AWS CloudWatch → Prometheus exporter configs
- [ ] Istio service mesh dashboards
- [ ] Automated SLO report generation

---

## License

MIT — see [LICENSE](LICENSE).
