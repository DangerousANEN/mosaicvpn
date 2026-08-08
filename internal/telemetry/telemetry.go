package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
)

// Report is the anonymous load-aware telemetry payload sent to the VPN provider's backend.
type Report struct {
	NodeID      string `json:"node_id"`
	PingMS      int    `json:"ping_ms"`
	ISP         string `json:"isp,omitempty"`
	Success     bool   `json:"success"`
	UserTier    string `json:"user_tier,omitempty"`
	ClientVer   string `json:"client_version,omitempty"`
	Platform    string `json:"platform,omitempty"`
}

// SendReport posts a telemetry report asynchronously in a background goroutine.
func SendReport(telemetryURL string, report Report) {
	if telemetryURL == "" {
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		data, err := json.Marshal(report)
		if err != nil {
			return
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, telemetryURL, bytes.NewReader(data))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("User-Agent", "MosaicVPN-Client/1.0")

		resp, err := http.DefaultClient.Do(req)
		if err == nil && resp != nil {
			_ = resp.Body.Close()
			logx.Info("telemetry sent successfully", "url", telemetryURL, "node_id", report.NodeID)
		}
	}()
}
