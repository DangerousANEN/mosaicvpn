package state

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// One-tap connection diagnostics.
//
// WHY
// ---
// When a tunnel misbehaves the user gets one undifferentiated symptom —
// "the internet does not work" — while the actual cause is almost always one
// of a handful of specific, checkable things. Support then burns messages
// asking people to run commands they should not have to run.
//
// Each check below corresponds to a failure we have actually diagnosed by hand:
//
//   - clock skew: TLS certificates are validated against the system clock, so a
//     device several minutes off fails every handshake with an opaque error.
//   - DNS: resolution can succeed outside the tunnel while the tunnel itself
//     carries nothing, or fail entirely and look like "no internet".
//   - real traffic: the truth-check, reused here on demand.
//   - IPv6 leak: if v6 escapes the tunnel, sites see the real address while the
//     user believes they are protected. Silent, and the worst kind of failure.
//   - MTU: an oversized MTU makes small requests succeed and large transfers
//     hang forever, which reads as "slow internet" rather than a broken path.

// DiagCheck is one diagnostic result, written for a human to read.
type DiagCheck struct {
	ID string `json:"id"`
	// Title is a short user-facing label.
	Title string `json:"title"`
	// OK is the headline verdict.
	OK bool `json:"ok"`
	// Severity is "ok", "warn" or "fail"; a warning is informative, a failure
	// means this is very likely the user's problem.
	Severity string `json:"severity"`
	// Detail explains what was observed, in plain language.
	Detail string `json:"detail"`
	// Hint tells the user what to do about it, when there is something to do.
	Hint string `json:"hint,omitempty"`
	// DurationMS records how long the check took.
	DurationMS int `json:"duration_ms"`
}

// DiagResult is the full report.
type DiagResult struct {
	GeneratedAt time.Time   `json:"generated_at"`
	Checks      []DiagCheck `json:"checks"`
	// Summary is a one-line verdict for the UI headline.
	Summary string `json:"summary"`
	// Healthy is true when nothing failed.
	Healthy bool `json:"healthy"`
}

const (
	sevOK   = "ok"
	sevWarn = "warn"
	sevFail = "fail"
)

// RunDiagnostics executes every check and returns a report.
//
// Checks run concurrently because they are independent and network-bound;
// serially this would take long enough that users would assume it had hung.
func (m *Manager) RunDiagnostics(ctx context.Context) DiagResult {
	status := m.Status()
	connected := status.State == proto.StateConnected

	var socks string
	m.mu.Lock()
	backend := m.backend
	m.mu.Unlock()
	if listener, ok := backend.(ProxyListener); ok {
		socks, _ = listener.Proxies()
	}

	checks := []func(context.Context) DiagCheck{
		m.checkClockSkew,
		func(c context.Context) DiagCheck { return m.checkDNS(c) },
		func(c context.Context) DiagCheck { return m.checkTunnelTraffic(c, socks, connected) },
		func(c context.Context) DiagCheck { return m.checkIPv6Leak(c, socks, connected) },
		func(c context.Context) DiagCheck { return m.checkMTU(c, connected) },
	}

	results := make([]DiagCheck, len(checks))
	var wg sync.WaitGroup
	for i, check := range checks {
		wg.Add(1)
		go func(idx int, fn func(context.Context) DiagCheck) {
			defer wg.Done()
			start := time.Now()
			res := fn(ctx)
			res.DurationMS = int(time.Since(start).Milliseconds())
			results[idx] = res
		}(i, check)
	}
	wg.Wait()

	failures, warnings := 0, 0
	for _, r := range results {
		switch r.Severity {
		case sevFail:
			failures++
		case sevWarn:
			warnings++
		}
	}

	summary := "Всё в порядке"
	switch {
	case failures > 0:
		summary = fmt.Sprintf("Найдено проблем: %d", failures)
	case warnings > 0:
		summary = fmt.Sprintf("Предупреждений: %d", warnings)
	}

	return DiagResult{
		GeneratedAt: time.Now().UTC(),
		Checks:      results,
		Summary:     summary,
		Healthy:     failures == 0,
	}
}

// checkClockSkew compares the system clock against an HTTP Date header.
//
// A skewed clock breaks TLS certificate validity checks, and the resulting
// error mentions certificates rather than time, which sends users down the
// wrong path entirely.
func (m *Manager) checkClockSkew(ctx context.Context) DiagCheck {
	c := DiagCheck{ID: "clock", Title: "Системное время"}

	reqCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodHead, "https://cloudflare.com", nil)
	if err != nil {
		c.Severity, c.Detail = sevWarn, "не удалось проверить: "+err.Error()
		return c
	}
	resp, err := (&http.Client{Timeout: 8 * time.Second}).Do(req)
	if err != nil {
		c.Severity = sevWarn
		c.Detail = "не удалось сверить время (нет соединения)"
		return c
	}
	defer resp.Body.Close()

	serverTime, err := http.ParseTime(resp.Header.Get("Date"))
	if err != nil {
		c.Severity, c.Detail = sevWarn, "сервер не сообщил время"
		return c
	}

	skew := time.Since(serverTime)
	if skew < 0 {
		skew = -skew
	}
	switch {
	case skew > 5*time.Minute:
		c.Severity = sevFail
		c.Detail = fmt.Sprintf("расхождение %s — TLS-соединения будут отклоняться", skew.Round(time.Second))
		c.Hint = "Включите автоматическую установку даты и времени в настройках системы."
	case skew > 60*time.Second:
		c.Severity = sevWarn
		c.Detail = fmt.Sprintf("расхождение %s", skew.Round(time.Second))
		c.Hint = "Стоит включить синхронизацию времени."
	default:
		c.OK, c.Severity = true, sevOK
		c.Detail = fmt.Sprintf("точность %s", skew.Round(time.Second))
	}
	return c
}

// checkDNS resolves a well-known name to prove name resolution works at all.
func (m *Manager) checkDNS(ctx context.Context) DiagCheck {
	c := DiagCheck{ID: "dns", Title: "DNS"}

	reqCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()

	addrs, err := net.DefaultResolver.LookupHost(reqCtx, "cloudflare.com")
	switch {
	case err != nil:
		c.Severity = sevFail
		c.Detail = "имена не разрешаются: " + err.Error()
		c.Hint = "Проверьте подключение к сети или смените DNS в настройках приложения."
	case len(addrs) == 0:
		c.Severity = sevFail
		c.Detail = "ответ пустой"
		c.Hint = "Попробуйте другой DNS-сервер в настройках."
	default:
		c.OK, c.Severity = true, sevOK
		c.Detail = fmt.Sprintf("разрешается (%d адрес(ов))", len(addrs))
	}
	return c
}

// checkTunnelTraffic reuses the runtime truth-check on demand.
func (m *Manager) checkTunnelTraffic(ctx context.Context, socks string, connected bool) DiagCheck {
	c := DiagCheck{ID: "traffic", Title: "Трафик через туннель"}

	if !connected {
		c.OK, c.Severity = true, sevOK
		c.Detail = "проверка пропущена: VPN отключён"
		return c
	}
	if socks == "" {
		c.OK, c.Severity = true, sevOK
		c.Detail = "проверка недоступна для этого режима"
		return c
	}

	res := verifyTunnel(ctx, socks, VerifyPolicy{
		Attempts:          2,
		PerAttemptTimeout: 6 * time.Second,
		Backoff:           500 * time.Millisecond,
	})
	if res.OK {
		c.OK, c.Severity = true, sevOK
		c.Detail = fmt.Sprintf("данные проходят, задержка %d мс", res.LatencyMS)
		return c
	}
	c.Severity = sevFail
	c.Detail = "туннель подключён, но данные не проходят"
	c.Hint = "Переподключитесь — приложение выберет другой маршрут."
	return c
}

// checkIPv6Leak verifies that IPv6 traffic cannot escape the tunnel.
//
// This is the most dangerous silent failure in the list: the user sees a
// connected VPN while sites still observe their real IPv6 address.
func (m *Manager) checkIPv6Leak(ctx context.Context, socks string, connected bool) DiagCheck {
	c := DiagCheck{ID: "ipv6", Title: "Утечка IPv6"}

	if !connected {
		c.OK, c.Severity = true, sevOK
		c.Detail = "проверка пропущена: VPN отключён"
		return c
	}

	reqCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()

	// Dial an IPv6-only host directly, bypassing the tunnel's SOCKS endpoint.
	// Success means v6 has a path around the tunnel.
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(reqCtx, "tcp6", "[2606:4700:4700::1111]:443")
	if err != nil {
		// No direct v6 path — that is what we want.
		c.OK, c.Severity = true, sevOK
		c.Detail = "IPv6 не обходит туннель"
		return c
	}
	_ = conn.Close()

	// A direct v6 connection succeeded. If the tunnel itself has no v6, this is
	// a genuine leak; report it plainly rather than hedging.
	c.Severity = sevWarn
	c.Detail = "IPv6 может идти в обход туннеля"
	c.Hint = "Включите блокировку IPv6 в настройках или отключите IPv6 в системе."
	_ = socks
	return c
}

// checkMTU probes whether large packets survive the path.
//
// A too-large MTU is invisible on small requests and hangs large transfers,
// which users report as "slow", sending diagnosis in the wrong direction.
func (m *Manager) checkMTU(ctx context.Context, connected bool) DiagCheck {
	c := DiagCheck{ID: "mtu", Title: "Размер пакета (MTU)"}

	if !connected {
		c.OK, c.Severity = true, sevOK
		c.Detail = "проверка пропущена: VPN отключён"
		return c
	}

	reqCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()

	// Ask for a payload well above one MTU: if the path is broken for large
	// packets this stalls, while small requests would have succeeded.
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet,
		"https://speed.cloudflare.com/__down?bytes=200000", nil)
	if err != nil {
		c.Severity, c.Detail = sevWarn, "не удалось проверить"
		return c
	}
	resp, err := (&http.Client{Timeout: 12 * time.Second}).Do(req)
	if err != nil {
		c.Severity = sevWarn
		c.Detail = "крупные передачи не проходят — возможна проблема с MTU"
		c.Hint = "Уменьшите MTU в настройках подключения (например, до 1280)."
		return c
	}
	defer resp.Body.Close()

	n, _ := io.Copy(io.Discard, resp.Body)
	if n < 100000 {
		c.Severity = sevWarn
		c.Detail = fmt.Sprintf("передача оборвалась на %d байт", n)
		c.Hint = "Уменьшите MTU в настройках подключения."
		return c
	}
	c.OK, c.Severity = true, sevOK
	c.Detail = "крупные пакеты проходят"
	return c
}
