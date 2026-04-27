// Package logx is a thin wrapper around the standard library log/slog
// package that gives the daemon a consistent structured-logging surface.
package logx

import (
	"context"
	"io"
	"log/slog"
	"os"
	"sync"
)

// Level aliases standard slog levels for callers that don't import slog.
type Level = slog.Level

const (
	LevelDebug = slog.LevelDebug
	LevelInfo  = slog.LevelInfo
	LevelWarn  = slog.LevelWarn
	LevelError = slog.LevelError
)

var (
	mu       sync.RWMutex
	current  io.Writer  = os.Stderr
	curLevel slog.Level = slog.LevelInfo
	logger              = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
)

// SetOutput replaces the destination of the global logger.
func SetOutput(w io.Writer, level slog.Level) {
	mu.Lock()
	defer mu.Unlock()
	current = w
	curLevel = level
	logger = slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: level}))
}

// SetLevel changes the active log level without changing the output.
func SetLevel(level slog.Level) {
	mu.Lock()
	defer mu.Unlock()
	curLevel = level
	logger = slog.New(slog.NewTextHandler(current, &slog.HandlerOptions{Level: level}))
}

// L returns the active logger.
func L() *slog.Logger {
	mu.RLock()
	defer mu.RUnlock()
	return logger
}

// With returns a logger that attaches the given attributes.
func With(args ...any) *slog.Logger { return L().With(args...) }

// Info, Warn, Error, Debug are convenience wrappers.
func Info(msg string, args ...any)  { L().Info(msg, args...) }
func Warn(msg string, args ...any)  { L().Warn(msg, args...) }
func Error(msg string, args ...any) { L().Error(msg, args...) }
func Debug(msg string, args ...any) { L().Debug(msg, args...) }

// InfoCtx etc. propagate context through the logger (useful for trace IDs).
func InfoCtx(ctx context.Context, msg string, args ...any) {
	L().InfoContext(ctx, msg, args...)
}
