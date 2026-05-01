// Local-DB GeoIP resolution backed by a MMDB file (MaxMind GeoLite2
// City schema, or any compatible flavour like db-ip.com lite).  When
// loaded, the file lookups are O(microseconds) and offline — no
// rate-limit, no flaky outbound HTTP, no leak of subscription server
// addresses to ip-api.com.
//
// rc47 ships db-ip.com's free city lite DB (CC-BY 4.0) downloaded
// once on first daemon launch into `<DataDir>/geo/city.mmdb`.  The
// download runs out-of-band; until it completes the package falls
// back to ip-api.com.  See `EnsureLocalDB` below for the download
// orchestration.
package geoip

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/oschwald/maxminddb-golang"
)

// localReader is the loaded MMDB. nil until LoadLocalDB succeeds; we
// store it behind atomic.Pointer so concurrent readers (the lookup
// path) never race against the loader / refresher.
var localReader atomic.Pointer[maxminddb.Reader]

// LoadLocalDB opens the MMDB at path and registers it as the active
// reader for subsequent Lookup calls. Safe to call repeatedly — each
// call replaces the previously-loaded reader and closes the old one.
// Returns an error without changing state if the file is missing or
// not a valid MMDB.
func LoadLocalDB(path string) error {
	r, err := maxminddb.Open(path)
	if err != nil {
		return err
	}
	old := localReader.Swap(r)
	if old != nil {
		_ = old.Close()
	}
	return nil
}

// HasLocalDB reports whether a MMDB has been loaded.
func HasLocalDB() bool {
	return localReader.Load() != nil
}

// mmdbCity is the projected subset of the GeoLite2-City / db-ip-city
// schema we consume. Both schemas share these top-level keys.
type mmdbCity struct {
	Country struct {
		ISOCode string `maxminddb:"iso_code"`
	} `maxminddb:"country"`
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`
	Location struct {
		Latitude  float64 `maxminddb:"latitude"`
		Longitude float64 `maxminddb:"longitude"`
	} `maxminddb:"location"`
}

// LookupLocal resolves host (IPv4/v6 literal or DNS name) against the
// loaded MMDB. Returns (Result, true, nil) on hit, (Result{}, false,
// nil) on miss, or (Result{}, false, err) on a hard failure (DB
// missing / DNS failed / record format unexpected).
func LookupLocal(ctx context.Context, host string) (Result, bool, error) {
	r := localReader.Load()
	if r == nil {
		return Result{}, false, errors.New("local geo db not loaded")
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return Result{}, false, errors.New("empty host")
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// Resolve the name through DirectResolver so the lookup
		// matches what ip-api.com would have seen — and never
		// loops back through any active tunnel.
		cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		ips, err := DirectResolver().LookupIPAddr(cctx, host)
		if err != nil || len(ips) == 0 {
			if err == nil {
				err = errors.New("no DNS answer")
			}
			return Result{}, false, err
		}
		ip = ips[0].IP
	}
	var rec mmdbCity
	if err := r.Lookup(ip, &rec); err != nil {
		return Result{}, false, err
	}
	if rec.Country.ISOCode == "" && rec.Location.Latitude == 0 && rec.Location.Longitude == 0 {
		return Result{}, false, nil
	}
	city := ""
	if rec.City.Names != nil {
		city = rec.City.Names["en"]
	}
	return Result{
		Country: rec.Country.ISOCode,
		City:    city,
		Lat:     rec.Location.Latitude,
		Lon:     rec.Location.Longitude,
	}, true, nil
}

// LocalDBPath returns the canonical filesystem path for the bundled
// MMDB.  We keep it inside `<DataDir>/geo/` so it persists across
// installer upgrades but is wiped when the user uninstalls Mosaic.
func LocalDBPath(dataDir string) string {
	return filepath.Join(dataDir, "geo", "city.mmdb")
}

// dbipLatestURL returns the db-ip.com lite city download URL for the
// given calendar month. The provider publishes a fresh DB on the
// first of each month under a predictable URL — older months stay
// downloadable indefinitely. The lite tier is CC-BY 4.0; we
// distribute the file as-is and expose the attribution text in the
// daemon log on first load.
func dbipLatestURL(year int, month time.Month) string {
	return fmt.Sprintf(
		"https://download.db-ip.com/free/dbip-city-lite-%04d-%02d.mmdb.gz",
		year, int(month),
	)
}

// downloadOnce is held while a single download is in flight so two
// concurrent EnsureLocalDB callers don't fan out duplicate fetches.
var downloadOnce sync.Mutex

// dlClient is a longer-deadline http.Client for the city-DB download.
// httpClient() caps the total roundtrip at 8 s which is fine for the
// ip-api.com JSON endpoint but trips on the ~50 MB MMDB.gz transfer.
var (
	dlClientOnce sync.Once
	dlClient     *http.Client
)

func downloadClient() *http.Client {
	dlClientOnce.Do(func() {
		dialer := &net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
			Resolver:  DirectResolver(),
		}
		dlClient = &http.Client{
			Timeout: 0,
			Transport: &http.Transport{
				Proxy:                 nil,
				DialContext:           dialer.DialContext,
				ForceAttemptHTTP2:     true,
				IdleConnTimeout:       60 * time.Second,
				TLSHandshakeTimeout:   10 * time.Second,
				ExpectContinueTimeout: 1 * time.Second,
			},
		}
	})
	return dlClient
}

// downloadCityDB streams the gzipped MMDB at url, decompresses it and
// writes the result to dest atomically (download to <dest>.part,
// rename on success).
func downloadCityDB(ctx context.Context, url, dest string) error {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "mosaicvpn/0.1 (geoip db sync)")
	resp, err := downloadClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("db-ip.com http %d for %s", resp.StatusCode, url)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmp := dest + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	gr, err := gzip.NewReader(resp.Body)
	if err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("gunzip: %w", err)
	}
	if _, err := io.Copy(f, gr); err != nil {
		_ = gr.Close()
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("write mmdb: %w", err)
	}
	_ = gr.Close()
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dest)
}

// EnsureLocalDB makes a best-effort attempt to ensure that a recent
// MMDB is loaded for offline GeoIP lookups. The contract is:
//
//  1. If `<dataDir>/geo/city.mmdb` exists and is newer than 35 days,
//     load it and return.
//  2. Otherwise download the current month's db-ip lite city DB, and
//     on failure the previous month, write atomically, load.
//  3. On any failure the caller's `Lookup`/`LookupBatch` paths fall
//     through to ip-api.com — this routine never returns a hard
//     error.  It logs through the supplied logf so the daemon can
//     surface progress / failures in `daemon.log`.
//
// Designed to be invoked async at startup. Cheap when the file is
// already fresh (single stat + open).
func EnsureLocalDB(ctx context.Context, dataDir string, logf func(string, ...any)) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	dest := LocalDBPath(dataDir)
	if st, err := os.Stat(dest); err == nil && time.Since(st.ModTime()) < 35*24*time.Hour {
		if err := LoadLocalDB(dest); err == nil {
			logf("geoip: loaded local db", "path", dest, "size", st.Size(), "age_d", int(time.Since(st.ModTime())/(24*time.Hour)))
			return
		} else {
			logf("geoip: local db open failed; will refresh", "path", dest, "err", err.Error())
		}
	}
	downloadOnce.Lock()
	defer downloadOnce.Unlock()
	// Re-check after acquiring the lock — another goroutine may have
	// already finished the download.
	if st, err := os.Stat(dest); err == nil && time.Since(st.ModTime()) < 35*24*time.Hour {
		if err := LoadLocalDB(dest); err == nil {
			logf("geoip: local db loaded after lock-wait", "path", dest)
			return
		}
	}
	now := time.Now().UTC()
	for _, off := range []int{0, -1, -2} {
		t := now.AddDate(0, off, 0)
		url := dbipLatestURL(t.Year(), t.Month())
		logf("geoip: downloading local db", "url", url)
		if err := downloadCityDB(ctx, url, dest); err != nil {
			logf("geoip: download failed", "url", url, "err", err.Error())
			continue
		}
		if err := LoadLocalDB(dest); err != nil {
			logf("geoip: load after download failed", "path", dest, "err", err.Error())
			continue
		}
		logf("geoip: local db ready (db-ip.com lite, CC-BY 4.0)", "path", dest)
		return
	}
	logf("geoip: local db unavailable, falling back to ip-api.com")
}
