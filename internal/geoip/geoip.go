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
