package api

import (
	"encoding/json"
	"net/http"

	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
)

// billingConfigPayload is the JSON body for both GET and PUT
// /v1/billing/config. Tokens returned on GET are masked; the PUT
// accepts full tokens (masked values are written through verbatim, so
// users should re-enter a fresh token rather than save the masked form).
type billingConfigPayload struct {
	RemnawaveURL   string `json:"remnawave_url"`
	RemnawaveToken string `json:"remnawave_token"`
	CryptoBotURL   string `json:"cryptobot_url,omitempty"`
	CryptoBotToken string `json:"cryptobot_token"`
	YookassaShopID    string `json:"yookassa_shop_id,omitempty"`
	YookassaSecretKey string `json:"yookassa_secret_key,omitempty"`
}

// handleBillingConfigGet returns the persisted billing credentials with
// tokens masked so the UI can display "configured / not configured"
// without leaking the secret over loopback to a potentially-logged response.
func (s *Server) handleBillingConfigGet(w http.ResponseWriter, r *http.Request) {
	rURL, rTok, cURL, cTok := s.store.GetBillingCredentials()
	yShop, yKey := s.store.GetYookassaCredentials()
	writeJSON(w, http.StatusOK, billingConfigPayload{
		RemnawaveURL:      rURL,
		RemnawaveToken:    maskToken(rTok),
		CryptoBotURL:      cURL,
		CryptoBotToken:    maskToken(cTok),
		YookassaShopID:    yShop,
		YookassaSecretKey: maskToken(yKey),
	})
}

// handleBillingConfigSet accepts full credentials, persists them to the
// store, and live-updates the billing.Client so the new config takes
// effect without a daemon restart.
func (s *Server) handleBillingConfigSet(w http.ResponseWriter, r *http.Request) {
	var req billingConfigPayload
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.store.SetBillingCredentials(req.RemnawaveURL, req.RemnawaveToken, req.CryptoBotURL, req.CryptoBotToken); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if req.YookassaShopID != "" || req.YookassaSecretKey != "" {
		if err := s.store.SetYookassaCredentials(req.YookassaShopID, req.YookassaSecretKey); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	s.SetBillingConfig(billing.Config{
		Remnawave: billing.RemnawaveConfig{BaseURL: req.RemnawaveURL, APIToken: req.RemnawaveToken},
		CryptoBot: billing.CryptoBotConfig{APIToken: req.CryptoBotToken, BaseURL: req.CryptoBotURL},
		Yookassa:  billing.YookassaConfig{ShopID: req.YookassaShopID, SecretKey: req.YookassaSecretKey},
	})
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// maskToken returns the first 4 and last 4 characters of a token for
// safe display. Tokens of length <= 8 are returned as-is (they are
// unlikely to be real secrets and masking would leave nothing visible).
func maskToken(tok string) string {
	if len(tok) <= 8 {
		return tok
	}
	return tok[:4] + "..." + tok[len(tok)-4:]
}
