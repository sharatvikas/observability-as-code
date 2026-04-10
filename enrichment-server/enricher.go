package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const enricherSystemPrompt = `You are a Senior SRE on-call. You receive a firing Kubernetes or AWS alert
and must provide an instant, actionable analysis.

Your response must be:
- 3-5 bullet points maximum
- Specific to the alert type and labels provided
- Lead with the most likely cause
- Give one concrete next step as a command or action
- Flag if this might be a false positive

Do NOT be verbose. Engineers read this at 3am.`

// Enricher calls Claude API to add context to an alert
type Enricher struct {
	client *anthropic.Client
	model  string
}

// NewEnricher creates an Enricher using ANTHROPIC_API_KEY from env
func NewEnricher() *Enricher {
	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		panic("ANTHROPIC_API_KEY not set")
	}
	client := anthropic.NewClient(option.WithAPIKey(apiKey))
	return &Enricher{client: client, model: "claude-haiku-4-5-20251001"} // Use Haiku for speed + cost
}

// Enrich generates an AI summary for the given alert
func (e *Enricher) Enrich(ctx context.Context, alert *Alert) (string, error) {
	prompt := buildAlertPrompt(alert)

	resp, err := e.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(e.model),
		MaxTokens: 400, // Keep it short — this is a Slack message
		System: []anthropic.TextBlockParam{
			{Text: enricherSystemPrompt},
		},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(prompt)),
		},
	})
	if err != nil {
		return "", fmt.Errorf("claude API error: %w", err)
	}

	var sb strings.Builder
	for _, block := range resp.Content {
		if block.Type == "text" {
			sb.WriteString(block.Text)
		}
	}
	return sb.String(), nil
}

func buildAlertPrompt(alert *Alert) string {
	var sb strings.Builder

	sb.WriteString(fmt.Sprintf("Alert: %s\n", alert.Labels["alertname"]))
	sb.WriteString(fmt.Sprintf("Severity: %s\n", alert.Labels["severity"]))

	if ns, ok := alert.Labels["namespace"]; ok {
		sb.WriteString(fmt.Sprintf("Namespace: %s\n", ns))
	}
	if pod, ok := alert.Labels["pod"]; ok {
		sb.WriteString(fmt.Sprintf("Pod: %s\n", pod))
	}
	if node, ok := alert.Labels["node"]; ok {
		sb.WriteString(fmt.Sprintf("Node: %s\n", node))
	}
	if job, ok := alert.Labels["job"]; ok {
		sb.WriteString(fmt.Sprintf("Service/Job: %s\n", job))
	}

	if summary, ok := alert.Annotations["summary"]; ok {
		sb.WriteString(fmt.Sprintf("\nSummary: %s\n", summary))
	}
	if desc, ok := alert.Annotations["description"]; ok {
		sb.WriteString(fmt.Sprintf("Description: %s\n", desc))
	}

	sb.WriteString(fmt.Sprintf("\nFired at: %s\n", alert.StartsAt.Format("2006-01-02 15:04:05 MST")))
	sb.WriteString("\nWhat is most likely happening and what should the on-call engineer do first?")

	return sb.String()
}
