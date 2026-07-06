#!/usr/bin/env python3
"""Wrap the repo's raw Prometheus rule files into PrometheusRule CRs.

The files under alerts/ and recording-rules/ are plain Prometheus `groups:`
documents. This wraps each one as a monitoring.coreos.com/v1 PrometheusRule with
the label the kube-prometheus operator selects on (release: kube-prometheus), so
`kubectl apply -f demo/prometheus-rules/` loads them additively.

Pure stdlib (no PyYAML): the raw file body is a valid YAML mapping, so we just
indent it two spaces under `spec:`.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "demo", "prometheus-rules")
SELECTOR_LABEL = ("release", "kube-prometheus")

MAPPING = [
    ("recording-rules/slo.yaml", "oac-slo-recording"),
    ("recording-rules/kubernetes.yaml", "oac-kubernetes-recording"),
    ("recording-rules/kubernetes-slo.yaml", "oac-kubernetes-slo-recording"),
    ("recording-rules/aws.yaml", "oac-aws-recording"),
    ("alerts/slo.yaml", "oac-slo-alerts"),
    ("alerts/kubernetes.yaml", "oac-kubernetes-alerts"),
    ("alerts/aws.yaml", "oac-aws-alerts"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for src, name in MAPPING:
        body = open(os.path.join(ROOT, src)).read()
        indented = "\n".join(("  " + ln if ln.strip() else ln)
                             for ln in body.splitlines())
        header = (
            "apiVersion: monitoring.coreos.com/v1\n"
            "kind: PrometheusRule\n"
            "metadata:\n"
            f"  name: {name}\n"
            "  namespace: monitoring\n"
            "  labels:\n"
            f"    {SELECTOR_LABEL[0]}: {SELECTOR_LABEL[1]}\n"
            "    app.kubernetes.io/part-of: observability-as-code\n"
            "spec:\n"
        )
        dest = os.path.join(OUT, f"{name}.yaml")
        with open(dest, "w") as f:
            f.write(header + indented + "\n")
        print("wrote", os.path.relpath(dest, ROOT))


if __name__ == "__main__":
    main()
