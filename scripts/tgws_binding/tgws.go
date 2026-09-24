// Package tgws embeds the tg-ws-proxy SOCKS5 engine as an Android library
// (MIT, github.com/d0mhate/-tg-ws-proxy-Manager-go). The MosaicVPN app uses
// it as a Telegram resilience layer: local SOCKS5 -> WebSocket+TLS ->
// Telegram DC (kws*.web.telegram.org behind Cloudflare) with direct-TCP and
// external MTProto fallbacks. This binding deliberately reuses the upstream
// internal packages instead of re-implementing them.
package tgws

import (
	"context"
	"errors"
	"log"
	"net"
	"strconv"
	"time"

	"tg-ws-proxy/internal/config"
	"tg-ws-proxy/internal/socks5"
)

// pickFreePort binds :0 on loopback, reads the assigned port and releases it.
// The socks5 engine then binds that port itself via Run(). The window between
// release and rebind is a negligible TOCTOU on a private loopback interface.
func pickFreePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port, nil
}

var errNotRunning = errors.New("tgws: engine not running")

// Proxy is a gomobile-bind handle around one local SOCKS5 server instance.
// Gomobile exposes exported methods on this type to Java/Kotlin.
type Proxy struct {
	cfg    config.Config
	logger *log.Logger
	srv    *socks5.Server
	cancel context.CancelFunc
	done   chan struct{}
	err    error

	logSink   *callbackWriter
	port      int
	startedAt time.Time
}

// callbackWriter adapts a mobile log callback into an io.Writer.
type callbackWriter struct {
	cb func(line string)
}

func (w *callbackWriter) Write(p []byte) (int, error) {
	if w != nil && w.cb != nil {
		w.cb(string(p))
	}
	return len(p), nil
}

// New builds a proxy handle. Port 0 lets the engine pick a free port;
// use Port() after Start() to learn it. Only loopback listening is allowed
// from the app layer, so no credentials are required.
func New() *Proxy {
	cfg := config.Default()
	cfg.Host = "127.0.0.1"
	cfg.Port = 0
	cfg.Verbose = false
	return &Proxy{
		cfg:  cfg,
		done: make(chan struct{}),
	}
}

// SetCFDomain points the Cloudflare route at a custom domain (optional).
func (p *Proxy) SetCFDomain(domain string) {
	p.cfg.UseCFProxy = domain != ""
	p.cfg.UseCFProxyFirst = false
	p.cfg.CFDomain = domain
}

// SetVerbose toggles verbose engine logging.
func (p *Proxy) SetVerbose(v bool) { p.cfg.Verbose = v }

// SetLogCallback routes engine logs to the app layer (Java callback).
func (p *Proxy) SetLogCallback(cb func(line string)) {
	p.logSink = &callbackWriter{cb: cb}
}

// Start launches the SOCKS5 server in the background. Returns an error
// message string; empty means success.
func (p *Proxy) Start() error {
	if p.srv != nil {
		return nil // already running
	}
	if p.cfg.Port == 0 {
		p.cfg.Port = 0 // chosen per-attempt below
	}
	ctx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel
	logger := log.New(p.logSink, "tgws ", log.LstdFlags)

	// Windows can transiently refuse rebinding a just-released port, so retry
	// with a fresh port until the engine actually accepts one.
	const attempts = 8
	for i := 0; i < attempts; i++ {
		if p.cfg.Port == 0 {
			port, err := pickFreePort()
			if err != nil {
				return err
			}
			p.cfg.Port = port
		}
		srv := socks5.NewServer(p.cfg, logger)
		done := make(chan struct{})
		var runErr error
		go func() {
			defer close(done)
			runErr = srv.Run(ctx)
		}()
		// Wait up to 1s for the bind to land.
		deadline := time.Now().Add(1 * time.Second)
		bound := false
		for time.Now().Before(deadline) {
			select {
			case <-done:
			default:
			}
			if runErr != nil {
				break
			}
			if portOpen(p.cfg.Host, p.cfg.Port) {
				bound = true
				break
			}
			time.Sleep(25 * time.Millisecond)
		}
		if bound {
			p.srv = srv
			p.done = done
			p.err = nil
			p.startedAt = time.Now()
			return nil
		}
		// Not bound: engine either died or never bound. Retry on a new port.
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
		}
		if runErr == nil {
			// Engine alive but port probe never passed; accept anyway.
			p.srv = srv
			p.done = done
			p.err = nil
			p.startedAt = time.Now()
			return nil
		}
		logger.Printf("bind attempt %d on port %d failed: %v", i+1, p.cfg.Port, runErr)
		p.cfg.Port = 0
	}
	cancel()
	return errors.New("tgws: could not bind a local port after " +
		"repeated attempts")
}

// portOpen reports whether the local port is accepting connections.
func portOpen(host string, port int) bool {
	ln, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err == nil {
		_ = ln.Close()
		return false // we could bind: engine did NOT take it
	}
	// Bind failure means something (the engine) already holds the port.
	conn, derr := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 150*time.Millisecond)
	if derr == nil {
		_ = conn.Close()
		return true
	}
	return false
}

// Port returns the bound local port (valid after Start()).
func (p *Proxy) Port() int { return p.cfg.Port }

// Running reports whether the engine loop is alive.
func (p *Proxy) Running() bool {
	select {
	case <-p.done:
		return false
	default:
		return true
	}
}

// Uptime returns seconds since Start().
func (p *Proxy) Uptime() int64 {
	if p.startedAt.IsZero() {
		return 0
	}
	return int64(time.Since(p.startedAt) / time.Second)
}

// Stop terminates the engine. Idempotent.
func (p *Proxy) Stop() {
	if p.cancel != nil {
		p.cancel()
		<-p.done
		p.cancel = nil
	}
	p.srv = nil
}

// Err returns the terminal error of a stopped engine, if any.
func (p *Proxy) Err() error { return p.err }
