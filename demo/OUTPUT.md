# Live import demo — dashboards + Prometheus rules

Captured evidence of importing this repo's 3 Grafana dashboards and loading its
Prometheus recording + alert rules onto a **live** local monitoring stack.

## Environment

| Component | Value |
|-----------|-------|
| Cluster | kind, context `kind-sre-platform` |
| Monitoring stack | kube-prometheus-stack (chart 83.6.0) in namespace `monitoring` |
| Grafana | http://localhost:3000 (admin/admin) |
| Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |
| Prometheus `ruleSelector` | `matchLabels: { release: kube-prometheus }` |
| Grafana Prometheus datasource UID | `prometheus` (default) |

The existing kube-prometheus release was **not** upgraded, deleted, or restarted.
Rules were added additively as new `PrometheusRule` CRs; dashboards were imported
via the Grafana HTTP API.

## Datasource remap

The dashboards select their datasource through a `${datasource}` template variable
(37 / 34 / 27 refs across the three files — no hard-coded panel UIDs). The variable's
default value is `prometheus`, which already matches the live Grafana datasource UID
`prometheus`, so **no remap was required**. The import script still queries
`GET /api/datasources`, finds the Prometheus-type datasource, and pins the template
variable's `current` value to the live UID for robustness.

```bash
curl -s -u admin:admin http://localhost:3000/api/datasources \
  | python3 -c "import sys,json;[print(d['uid'],d['type'],d.get('isDefault')) for d in json.load(sys.stdin)]"
# alertmanager alertmanager False
# prometheus   prometheus   True
```

## 1. Dashboard import (POST /api/dashboards/db, overwrite:true)

Script: for each `dashboards/json/*.json`, pin the datasource template var to the live
UID, set `id:null`, and POST with `overwrite:true`. Full responses in
[`import-responses.json`](./import-responses.json).

```json
{"status":"success","uid":"service-golden-signals","slug":"service-golden-signals-red","url":"/d/service-golden-signals/service-golden-signals-red","version":1}
{"status":"success","uid":"kubernetes-cluster-health","slug":"kubernetes-cluster-health","url":"/d/kubernetes-cluster-health/kubernetes-cluster-health","version":1}
{"status":"success","uid":"slo-error-budget","slug":"slo-error-budget","url":"/d/slo-error-budget/slo-error-budget","version":1}
```

All three returned `status: success`.

## 2. Prometheus rules loaded (PrometheusRule CRs)

The raw rule files under `alerts/` and `recording-rules/` are plain Prometheus
`groups:` documents. They were wrapped into `PrometheusRule` CRs (label
`release: kube-prometheus` so the operator selects them) — generator output lives in
[`prometheus-rules/`](./prometheus-rules/).

```bash
kubectl apply -f demo/prometheus-rules/
# prometheusrule.monitoring.coreos.com/oac-aws-alerts created
# prometheusrule.monitoring.coreos.com/oac-aws-recording created
# prometheusrule.monitoring.coreos.com/oac-kubernetes-alerts created
# prometheusrule.monitoring.coreos.com/oac-kubernetes-recording created
# prometheusrule.monitoring.coreos.com/oac-kubernetes-slo-recording created
# prometheusrule.monitoring.coreos.com/oac-slo-alerts created
# prometheusrule.monitoring.coreos.com/oac-slo-recording created
```

Verification — Prometheus picked up all 7 files (26 groups, 106 rules) with **0 errors**:

```bash
curl -s http://localhost:9090/api/v1/rules \
  | python3 -c "import sys,json,collections; \
d=json.load(sys.stdin)['data']['groups']; \
o=[g for g in d if 'monitoring-oac-' in g['file']]; \
h=collections.Counter(r['health'] for g in o for r in g['rules']); \
print('oac groups:',len(o),'| health:',dict(h))"
# oac groups: 26 | health: {'ok': 70, 'unknown': 36}
```

`ok: 70` rules already evaluated cleanly; `unknown: 36` are pending their first
evaluation (5-minute AWS intervals + multi-day windows). No rule reported a
`lastError`.

## 3. Sample PromQL — which panels have real data

Full results in [`query-results.json`](./query-results.json).

| Dashboard / panel | PromQL (first line) | Result |
|-------------------|---------------------|--------|
| K8s cluster-health · Nodes Ready | `sum(kube_node_status_condition{condition="Ready",status="true"})` | **1** |
| K8s cluster-health · Cluster CPU Util % | `100 * sum(namespace:cpu_usage:rate5m) / sum(kube_node_status_allocatable{resource="cpu"})` | **2.10 %** |
| K8s cluster-health · Cluster Mem Util % | `100 * sum(namespace:memory_usage:sum) / sum(kube_node_status_allocatable{resource="memory"})` | **19.57 %** |
| K8s cluster-health · Node CPU Util | `100 * node:cpu_utilization:rate5m` (repo recording rule) | **6.72 %** |
| K8s cluster-health · Running pods | `count(kube_pod_status_phase{phase="Running"})` | **15** |
| repo recording rule sanity | `namespace:cpu_usage:rate5m` | **3 series** |
| Service RED · Request Rate | `sum(rate(http_requests_total[5m]))` | *empty* |
| SLO · error rate | `job:request_error_rate:ratio_rate1h` | *empty* |
| SLO · budget remaining | `job:error_budget_remaining:ratio_rate30d` | *empty* |

**Why RED and SLO panels are empty:** the `service-golden-signals` and
`slo-error-budget` dashboards (and the SLO recording rules that feed them) are built
on application RED metrics — `http_requests_total` and
`http_request_duration_seconds_bucket`. This single-node kind cluster runs no
instrumented demo app exposing those metrics, so the queries return no series. This
is expected, not a failure. The **kubernetes-cluster-health** dashboard is driven by
`node-exporter` + `kube-state-metrics` (both running), so its panels — including the
repo's own recording rules (`namespace:cpu_usage:rate5m`, `node:cpu_utilization:rate5m`)
— render real data.

## 4. Dashboard URLs

- Service Golden Signals (RED): http://localhost:3000/d/service-golden-signals
- Kubernetes Cluster Health: http://localhost:3000/d/kubernetes-cluster-health
- SLO / Error Budget: http://localhost:3000/d/slo-error-budget
