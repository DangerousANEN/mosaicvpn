// Command tgws is the MosaicVPN Telegram resilience engine: a standalone
// tg-ws-proxy (MIT, github.com/d0mhate/-tg-ws-proxy-Manager-go) runner that
// ships as an executable in the app's jniLibs (libtgws.so) and is spawned
// out-of-process by the Kotlin TgWsBridge.
//
// The engine exposes a local SOCKS5 server that carries Telegram DC traffic
// over WebSocket+TLS to kws*.web.telegram.org (Telegram domains behind
// Cloudflare), with direct-TCP and external MTProto fallbacks. The bridge
// parses the first stdout line `LISTENING 127.0.0.1:<port>` to learn the
// chosen port when -port 0 is requested.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"tg-ws-proxy/internal/config"
	"tg-ws-proxy/internal/socks5"
)

func pickFreePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port, nil
}

func main() {
	host := flag.String("host", "127.0.0.1", "SOCKS5 listen host")
	port := flag.Int("port", 0, "SOCKS5 listen port (0 = pick free)")
	verbose := flag.Bool("verbose", false, "verbose logging")
	mode := flag.String("mode", "socks", "engine mode: socks")
	flag.Parse()
	if *mode != "socks" {
		fmt.Fprintf(os.Stderr, "tgws: unsupported mode %q\n", *mode)
		os.Exit(2)
	}

	if *port == 0 {
		p, err := pickFreePort()
		if err != nil {
			fmt.Fprintf(os.Stderr, "tgws: pick free port: %v\n", err)
			os.Exit(1)
		}
		*port = p
	}

	cfg := config.Default()
	cfg.Host = *host
	cfg.Port = *port
	cfg.Verbose = *verbose

	logger := log.New(os.Stderr, "tgws ", log.LstdFlags)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	// Pre-bind the port so LISTENING is printed only when the address is
	// actually ours; Run() re-binds it internally.
	fmt.Printf("LISTENING %s:%d\n", *host, *port)
	os.Stdout.Sync()

	srv := socks5.NewServer(cfg, logger)
	if err := srv.Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "tgws: serve: %v\n", err)
		os.Exit(1)
	}
}
