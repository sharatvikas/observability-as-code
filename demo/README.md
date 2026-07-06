# demo/ — import dashboards + Prometheus rules into any Grafana/Prometheus

This directory shows how to load the repo's observability-as-code assets into a
running stack and prove they work. [`OUTPUT.md`](./OUTPUT.md) is the captured
evidence from a live kind + kube-prometheus-stack run.

## What's here

| File | Purpose |
|------|---------|
| `prometheus-rules/*.yaml` | The repo's `alerts/` and `recording-rules/` wrapped as `PrometheusRule` CRs (label `release: kube-prometheus`). |
| `import-responses.json` | Grafana `POST /api/dashboards/db` responses for all 3 dashboards. |
| `query-results.json` | Sample PromQL results proving which panels have data. |
| `OUTPUT.md` | Full run log: commands, responses, verification. |

## Import the 3 dashboards into any Grafana

The dashboards use a `${datasource}` template variable, so they work against any
Prometheus datasource. The snippet below auto-detects the Prometheus datasource UID
and pins the template variable to it before importing.

```bash
GRAFANA=http://localhost:3000
AUTH=admin:admin

# Discover the Prometheus datasource UID in the target Grafana
DS_UID=$(curl -s -u "$AUTH" "$GRAFANA/api/datasources" \
  | python3 -c "import sys,json;print(next(d['uid'] for d in json.load(sys.stdin) if d['type']=='prometheus'))")

for f in dashboards/json/*.json; do
  python3 - "$f" "$DS_UID" <<'PY' > /tmp/payload.json
import json,sys
dash=json.load(open(sys.argv[1])); uid=sys.argv[2]
for v in dash.get('templating',{}).get('list',[]):
    if v.get('type')=='datasource':
        v['current']={'selected':True,'text':uid,'value':uid}
dash['id']=None
json.dump({'dashboard':dash,'overwrite':True,'folderUid':''}, open('/tmp/payload.json','w'))
PY
  curl -s -u "$AUTH" -H 'Content-Type: application/json' \
    -d @/tmp/payload.json "$GRAFANA/api/dashboards/db"
  echo
done
```

Each call returns `{"status":"success","uid":...,"url":"/d/<uid>/..."}`.

> Note: if the target Grafana hard-codes datasource UIDs in panels (instead of a
> template variable), also rewrite each `"datasource": {"uid":"..."}` to `$DS_UID`.
> These dashboards don't — they use `${datasource}` everywhere.

## Load the Prometheus rules

With the Prometheus Operator (kube-prometheus-stack), apply the pre-built CRs. The
label must match the Prometheus CR's `ruleSelector`
(`kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.ruleSelector}'`).

```bash
kubectl apply -f demo/prometheus-rules/
# verify the operator loaded them
curl -s http://localhost:9090/api/v1/rules | python3 -c \
  "import sys,json;print([g['name'] for g in json.load(sys.stdin)['data']['groups'] if 'oac-' in g['file']])"
```

Without the operator (vanilla Prometheus), point `rule_files:` in `prometheus.yml`
at the raw `alerts/*.yaml` and `recording-rules/*.yaml` and reload
(`curl -XPOST http://localhost:9090/-/reload`).

## Regenerate the CRs from the raw rule files

```bash
python3 demo/gen-prometheus-rules.py   # see file for the mapping table
```
