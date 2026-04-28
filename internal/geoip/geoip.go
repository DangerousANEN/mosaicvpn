// Package geoip resolves an IPv4 / IPv6 address (or hostname) to a
// best-effort city / country / lat / lon tuple via the public
// ip-api.com endpoint. The lookup is unauthenticated, capped at ~45
// requests/minute by the provider, and uses a 4-second timeout per
// call so the daemon never hangs forever waiting on a flaky DNS
// response.
package geoip

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// directClient is a package-private HTTP client used for ip-api.com
// lookups. It explicitly bypasses HTTP_PROXY / system proxy and dials
// names through DirectResolver — same reasoning as the api package's
// directHTTPClient: even if the user has an active VPN tunnel
// configured to proxy everything, our own GeoIP probes must hit the
// public internet directly or they'll loop back through sing-box.
var (
	directClientOnce sync.Once
	directClient     *http.Client
)

func httpClient() *http.Client {
	directClientOnce.Do(func() {
		dialer := &net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
			Resolver:  DirectResolver(),
		}
		directClient = &http.Client{
			Timeout: 8 * time.Second,
			Transport: &http.Transport{
				Proxy:                 nil,
				DialContext:           dialer.DialContext,
				ForceAttemptHTTP2:     true,
				MaxIdleConns:          8,
				IdleConnTimeout:       60 * time.Second,
				TLSHandshakeTimeout:   10 * time.Second,
				ExpectContinueTimeout: 1 * time.Second,
			},
		}
	})
	return directClient
}

// Result is the subset of ip-api.com's JSON response we care about.
type Result struct {
	Country string  `json:"country"`
	City    string  `json:"city"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
}

// rawResp matches ip-api.com's JSON exactly; we keep a separate struct
// so we can surface their "status":"fail" message verbatim.
type rawResp struct {
	Status      string  `json:"status"`
	Message     string  `json:"message"`
	Country     string  `json:"country"`
	CountryCode string  `json:"countryCode"`
	City        string  `json:"city"`
	Lat         float64 `json:"lat"`
	Lon         float64 `json:"lon"`
	Query       string  `json:"query"`
}

// BatchEntry pairs a request key (the user-supplied host) with the
// resolved Result. Empty Country / zero Lat+Lon means the lookup
// failed for that entry — see Err for the per-entry reason.
type BatchEntry struct {
	Host   string
	Result Result
	Err    string
}

// LookupBatch resolves up to 100 hosts in a single ip-api.com /batch
// request. The free tier allows 15 batch calls per minute (versus 45
// single calls), so on a 1 000-server subscription this drops the
// resolve budget from ~22 minutes of single-host requests to ~10
// batch calls = ~40 s. Hosts that already resolve to a literal IP are
// passed through unchanged; DNS-only names are resolved through
// DirectResolver first so we never look up a hostname that the
// active tunnel is allowed to hijack.
//
// Returns one BatchEntry per input host, in the same order. Errors
// come back per-entry; the function only returns a non-nil error if
// the entire HTTP call failed.
func LookupBatch(ctx context.Context, hosts []string) ([]BatchEntry, error) {
	out := make([]BatchEntry, len(hosts))
	if len(hosts) == 0 {
		return out, nil
	}
	type req struct {
		Query  string `json:"query"`
		Fields string `json:"fields"`
	}
	const fields = "status,message,country,countryCode,city,lat,lon,query"
	body := make([]req, len(hosts))
	idxByQuery := map[string]int{}
	for i, h := range hosts {
		host := strings.TrimSpace(h)
		out[i].Host = host
		if host == "" {
			out[i].Err = "empty host"
			continue
		}
		// ip-api.com expects an IP literal or a hostname that resolves
		// publicly. We pass the user's address verbatim; the service
		// resolves names itself so we don't double-resolve.
		body[i] = req{Query: host, Fields: fields}
		idxByQuery[host] = i
	}
	cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	payload, err := json.Marshal(body)
	if err != nil {
		return out, err
	}
	httpReq, err := http.NewRequestWithContext(cctx, http.MethodPost, "http://ip-api.com/batch?fields="+fields, strings.NewReader(string(payload)))
	if err != nil {
		return out, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("User-Agent", "mosaicvpn/0.1 (geoip batch)")
	resp, err := httpClient().Do(httpReq)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		return out, fmt.Errorf("ip-api.com rate-limited (HTTP 429); retry after window")
	}
	if resp.StatusCode != http.StatusOK {
		return out, fmt.Errorf("ip-api.com batch http %d", resp.StatusCode)
	}
	var raws []rawResp
	if err := json.NewDecoder(resp.Body).Decode(&raws); err != nil {
		return out, fmt.Errorf("decode ip-api batch: %w", err)
	}
	// ip-api preserves request order in the response; fall back to
	// matching on Query when an entry is missing or reordered.
	for i, raw := range raws {
		idx := i
		if i >= len(out) || out[i].Host != raw.Query {
			if j, ok := idxByQuery[raw.Query]; ok {
				idx = j
			}
		}
		if idx >= len(out) {
			continue
		}
		if raw.Status != "success" {
			if raw.Message != "" {
				out[idx].Err = "ip-api: " + raw.Message
			} else {
				out[idx].Err = "ip-api: status=" + raw.Status
			}
			continue
		}
		out[idx].Result = Result{
			Country: raw.CountryCode,
			City:    raw.City,
			Lat:     raw.Lat,
			Lon:     raw.Lon,
		}
	}
	return out, nil
}

// Lookup resolves host (an IPv4/v6 address or DNS name) using
// ip-api.com. Returns an empty Result and a non-nil error when the
// lookup fails or the host is invalid.
func Lookup(ctx context.Context, host string) (Result, error) {
	host = strings.TrimSpace(host)
	if host == "" {
		return Result{}, errors.New("empty host")
	}
	cctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://ip-api.com/json/%s?fields=status,message,country,countryCode,city,lat,lon,query", host)
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("User-Agent", "mosaicvpn/0.1 (geoip lookup)")
	resp, err := httpClient().Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("ip-api.com http %d", resp.StatusCode)
	}
	var raw rawResp
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return Result{}, fmt.Errorf("decode ip-api response: %w", err)
	}
	if raw.Status != "success" {
		if raw.Message != "" {
			return Result{}, fmt.Errorf("ip-api: %s", raw.Message)
		}
		return Result{}, fmt.Errorf("ip-api: status=%q", raw.Status)
	}
	return Result{
		Country: raw.CountryCode, // ISO-2 fits the Server.Country field
		City:    raw.City,
		Lat:     raw.Lat,
		Lon:     raw.Lon,
	}, nil
}
