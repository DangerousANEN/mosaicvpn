package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	urlpkg "net/url"
	"strings"
)

// AccountServiceError is a safe, user-actionable error returned by the hosted
// Mosaic account authority. It deliberately contains no request body, session
// token or provider URL.
type AccountServiceError struct {
	Status int
	Code   string
}

func (e *AccountServiceError) Error() string {
	if e.Code != "" {
		return e.Code
	}
	return fmt.Sprintf("account service returned status %d", e.Status)
}

// callAccountService executes a JSON request against the hosted account
// authority. The session token is sent in JSON because the existing hosted API
// contract accepts both Telegram-pairing and email web sessions this way.
func (v *BotLinkVerifier) callAccountService(ctx context.Context, method, path, sessionToken string, payload map[string]any, out any) error {
	if v == nil || strings.TrimSpace(v.BaseURL) == "" || strings.TrimSpace(sessionToken) == "" {
		return ErrVerifierUnavailable
	}
	body := map[string]any{}
	for key, value := range payload {
		body[key] = value
	}
	body["token"] = sessionToken
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(v.BaseURL, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := v.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrVerifierUnavailable, err)
	}
	defer resp.Body.Close()
	response, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("%w: unreadable response", ErrVerifierUnavailable)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		var errorBody struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(response, &errorBody)
		return &AccountServiceError{Status: resp.StatusCode, Code: errorBody.Error}
	}
	if out == nil || len(response) == 0 {
		return nil
	}
	if err := json.Unmarshal(response, out); err != nil {
		return fmt.Errorf("%w: malformed response", ErrVerifierUnavailable)
	}
	return nil
}

// getAccountService calls a hosted read endpoint. The account authority
// exposes these reads as GET; its access logger redacts the token parameter.
func (v *BotLinkVerifier) getAccountService(ctx context.Context, path, sessionToken string, out any) error {
	if v == nil || strings.TrimSpace(v.BaseURL) == "" || strings.TrimSpace(sessionToken) == "" {
		return ErrVerifierUnavailable
	}
	endpoint, err := urlpkg.Parse(strings.TrimRight(v.BaseURL, "/") + path)
	if err != nil {
		return err
	}
	query := endpoint.Query()
	query.Set("token", sessionToken)
	endpoint.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return err
	}
	client := v.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrVerifierUnavailable, err)
	}
	defer resp.Body.Close()
	response, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("%w: unreadable response", ErrVerifierUnavailable)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		var errorBody struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(response, &errorBody)
		return &AccountServiceError{Status: resp.StatusCode, Code: errorBody.Error}
	}
	if out != nil && len(response) > 0 {
		if err := json.Unmarshal(response, out); err != nil {
			return fmt.Errorf("%w: malformed response", ErrVerifierUnavailable)
		}
	}
	return nil
}
