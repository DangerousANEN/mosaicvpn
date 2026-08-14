package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// unifiedAccountProfile mirrors the hosted account contract. Monetary amounts
// remain integer kopecks alongside the human-readable RUB amount so the UI
// never derives financial values from floating-point arithmetic.
type unifiedAccountProfile struct {
	AccountID       string `json:"account_id"`
	Status          string `json:"status"`
	Tier            string `json:"tier"`
	BalanceRub      int64  `json:"balance"`
	BalanceKopecks  int64  `json:"balance_kopecks"`
	Currency        string `json:"currency"`
	TrialEndsAt     string `json:"trial_ends_at"`
	ShortUUID       string `json:"short_uuid"`
	SubscriptionURL string `json:"sub_url"`
	Billing         struct {
		PricePerDayRub          int64  `json:"price_per_day_rub"`
		Timezone                string `json:"timezone"`
		CheckoutDiscountPercent int64  `json:"checkout_discount_percent"`
	} `json:"billing"`
}

type checkoutProvider struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	Currency     string `json:"currency"`
	Available    bool   `json:"available"`
	MinAmountRub int64  `json:"min_amount_rub"`
	MaxAmountRub int64  `json:"max_amount_rub"`
}

type checkoutOptionsResponse struct {
	Providers []checkoutProvider `json:"providers"`
}

type checkoutCreateRequest struct {
	AmountRub int64  `json:"amount_rub"`
	Provider  string `json:"provider,omitempty"`
}

type checkoutCreateResponse struct {
	OK          bool   `json:"ok"`
	Provider    string `json:"provider"`
	CheckoutURL string `json:"checkout_url"`
	AmountRub   int64  `json:"amount_rub"`
	Message     string `json:"message"`
}

func (s *Server) accountAuthority() (*BotLinkVerifier, string, bool) {
	verifier, ok := s.linkVerifier.(*BotLinkVerifier)
	if !ok || verifier == nil {
		return nil, "", false
	}
	account := s.store.GetAccount()
	// A paired Telegram account has a web session; an email account has both
	// the web token and a client token. The direct token is also valid for the
	// hosted unified account endpoints, so it is a compatible fallback.
	token := strings.TrimSpace(account.SessionToken)
	if token == "" {
		token = strings.TrimSpace(account.DirectToken)
	}
	return verifier, token, token != ""
}

func writeAccountServiceError(w http.ResponseWriter, err error) {
	var remote *AccountServiceError
	if errors.As(err, &remote) {
		status := remote.Status
		if status < 400 || status > 599 {
			status = http.StatusBadGateway
		}
		code := remote.Code
		if code == "" {
			code = "account service request failed"
		}
		writeError(w, status, code)
		return
	}
	if errors.Is(err, ErrVerifierUnavailable) {
		writeError(w, http.StatusServiceUnavailable, "account service is temporarily unavailable")
		return
	}
	writeError(w, http.StatusBadGateway, "account service request failed")
}

func (s *Server) handleUnifiedAccountProfile(w http.ResponseWriter, r *http.Request) {
	verifier, token, ok := s.accountAuthority()
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"linked": false})
		return
	}
	var profile unifiedAccountProfile
	if err := verifier.getAccountService(r.Context(), "/api/billing/profile", token, &profile); err != nil {
		writeAccountServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"linked": true, "account": profile})
}

func (s *Server) handleAccountAccessAction(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		verifier, token, ok := s.accountAuthority()
		if !ok {
			writeError(w, http.StatusForbidden, "no linked account")
			return
		}
		var result map[string]any
		if err := verifier.callAccountService(r.Context(), http.MethodPost, "/api/account/"+action, token, nil, &result); err != nil {
			writeAccountServiceError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, result)
	}
}

func (s *Server) handleCheckoutOptions(w http.ResponseWriter, r *http.Request) {
	verifier, token, ok := s.accountAuthority()
	if !ok {
		writeError(w, http.StatusForbidden, "no linked account")
		return
	}
	var options checkoutOptionsResponse
	if err := verifier.getAccountService(r.Context(), "/api/checkout/options", token, &options); err != nil {
		writeAccountServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, options)
}

func (s *Server) handleCheckoutCreate(w http.ResponseWriter, r *http.Request) {
	verifier, token, ok := s.accountAuthority()
	if !ok {
		writeError(w, http.StatusForbidden, "no linked account")
		return
	}
	var request checkoutCreateRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid checkout request")
		return
	}
	if request.AmountRub < 10 || request.AmountRub > 365 {
		writeError(w, http.StatusBadRequest, "amount_rub must be between 10 and 365")
		return
	}
	payload := map[string]any{"amount_rub": request.AmountRub}
	if request.Provider != "" {
		payload["provider"] = request.Provider
	}
	var result checkoutCreateResponse
	if err := verifier.callAccountService(r.Context(), http.MethodPost, "/api/checkout/create", token, payload, &result); err != nil {
		writeAccountServiceError(w, err)
		return
	}
	if !result.OK || strings.TrimSpace(result.CheckoutURL) == "" {
		writeError(w, http.StatusBadGateway, "checkout service returned an incomplete response")
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

func (s *Server) handleCheckoutStatus(w http.ResponseWriter, r *http.Request) {
	verifier, token, ok := s.accountAuthority()
	if !ok {
		writeError(w, http.StatusForbidden, "no linked account")
		return
	}
	invoiceID, err := strconv.ParseInt(r.PathValue("invoiceID"), 10, 64)
	if err != nil || invoiceID <= 0 {
		writeError(w, http.StatusBadRequest, "invalid invoice id")
		return
	}
	var result map[string]any
	path := "/api/checkout/status?invoice_id=" + url.QueryEscape(strconv.FormatInt(invoiceID, 10))
	if err := verifier.getAccountService(r.Context(), path, token, &result); err != nil {
		writeAccountServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleSubscriptionLinkRotate(w http.ResponseWriter, r *http.Request) {
	verifier, token, ok := s.accountAuthority()
	if !ok {
		writeError(w, http.StatusForbidden, "no linked account")
		return
	}
	var result map[string]any
	if err := verifier.callAccountService(r.Context(), http.MethodPost, "/api/subscription/link/rotate", token, nil, &result); err != nil {
		writeAccountServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}
