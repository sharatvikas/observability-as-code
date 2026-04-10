// enrichment-server — Alertmanager webhook that enriches alerts with AI context
// before routing to Slack/PagerDuty.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"
)

type AlertmanagerWebhook struct {
	Version  string  `json:"version"`
	GroupKey string  `json:"groupKey"`
	Alerts   []Alert `json:"alerts"`
	GroupLabels      map[string]string `json:"groupLabels"`
	CommonLabels     map[string]string `json:"commonLabels"`
	CommonAnnotations map[string]string `json:"commonAnnotations"`
}

type Alert struct {
	Status      string            `json:"status"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    time.Time         `json:"startsAt"`
	EndsAt      time.Time         `json:"endsAt"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	enricher := NewEnricher()

	mux := http.NewServeMux()
	mux.HandleFunc("/webhook", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			slog.Error("failed to read request body", "error", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		var webhook AlertmanagerWebhook
		if err := json.Unmarshal(body, &webhook); err != nil {
			slog.Error("failed to parse webhook", "error", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		slog.Info("received alerts", "count", len(webhook.Alerts), "group", webhook.GroupKey)

		for i, alert := range webhook.Alerts {
			if alert.Status != "firing" {
				continue
			}

			enriched, err := enricher.Enrich(r.Context(), &webhook.Alerts[i])
			if err != nil {
				slog.Error("enrichment failed", "alert", alert.Labels["alertname"], "error", err)
				continue
			}

			if err := sendToSlack(enriched, alert); err != nil {
				slog.Error("slack notification failed", "error", err)
			}
		}

		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, `{"status":"ok"}`)
	})

	slog.Info("enrichment server starting", "port", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func sendToSlack(aiSummary string, alert Alert) error {
	webhookURL := os.Getenv("SLACK_WEBHOOK_URL")
	if webhookURL == "" {
		return nil
	}

	severity := alert.Labels["severity"]
	alertName := alert.Labels["alertname"]
	namespace := alert.Labels["namespace"]
	summary := alert.Annotations["summary"]
	runbook := alert.Annotations["runbook"]
	dashboard := alert.Annotations["dashboard"]

	emoji := "⚠️"
	switch severity {
	case "critical":
		emoji = "🔴"
	case "warning":
		emoji = "🟠"
	}

	text := fmt.Sprintf(`%s *ALERT: %s*
Severity: %s | Namespace: %s
Summary: %s

*AI Analysis:*
%s`,
		emoji, alertName, severity, namespace, summary, aiSummary,
	)

	if runbook != "" {
		text += fmt.Sprintf("\n<Runbook: %s>", runbook)
	}
	if dashboard != "" {
		text += fmt.Sprintf(" | <Dashboard: %s>", dashboard)
	}

	payload, _ := json.Marshal(map[string]string{"text": text})

	resp, err := http.Post(webhookURL, "application/json",
		newJSONReader(payload))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("slack returned %d", resp.StatusCode)
	}
	return nil
}

func newJSONReader(data []byte) io.Reader {
	return &bytesReader{data: data, pos: 0}
}

type bytesReader struct {
	data []byte
	pos  int
}

func (b *bytesReader) Read(p []byte) (n int, err error) {
	if b.pos >= len(b.data) {
		return 0, io.EOF
	}
	n = copy(p, b.data[b.pos:])
	b.pos += n
	return n, nil
}
