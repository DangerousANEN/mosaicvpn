package store

import (
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// newTestStore builds a Store backed by a temp dir so each test is isolated.
func newAccountTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "store.json"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return s
}

func TestNewLinkCodeShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		code, err := NewLinkCode()
		if err != nil {
			t.Fatalf("NewLinkCode: %v", err)
		}
		if len(code) != LinkCodeLength {
			t.Fatalf("length = %d, want %d (%q)", len(code), LinkCodeLength, code)
		}
		for _, r := range code {
			if !strings.ContainsRune(linkCodeAlphabet, r) {
				t.Fatalf("code %q contains %q outside alphabet", code, r)
			}
		}
		// Ambiguous glyphs must never appear: users type these by hand off a
		// phone screen and 0/O, 1/I/L confusion causes failed redemptions.
		if strings.ContainsAny(code, "01OIL") {
			t.Fatalf("code %q contains ambiguous characters", code)
		}
		seen[code] = true
	}
	// 200 draws from a 31^8 space must not collide; a duplicate here means
	// the generator is not actually random.
	if len(seen) != 200 {
		t.Fatalf("got %d unique codes out of 200 — generator not random", len(seen))
	}
}

func TestNormalizeLinkCode(t *testing.T) {
	cases := map[string]string{
		"abcd2345":   "ABCD2345",
		" ABCD2345 ": "ABCD2345",
		"ABCD-2345":  "ABCD2345",
		"abcd 2345":  "ABCD2345",
		"":           "",
	}
	for in, want := range cases {
		if got := NormalizeLinkCode(in); got != want {
			t.Errorf("NormalizeLinkCode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIssueAndRedeemLinkCode(t *testing.T) {
	s := newAccountTestStore(t)

	issued, err := s.IssueLinkCode(12345, "alice", "tok-abc", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	if issued.Code == "" || issued.TelegramID != 12345 {
		t.Fatalf("unexpected issued code: %+v", issued)
	}
	if issued.Used() {
		t.Fatal("freshly issued code must not be marked used")
	}

	// Account must not be linked until the code is actually redeemed.
	if got := s.GetAccount(); got.TelegramID != 0 {
		t.Fatalf("account linked before redemption: %+v", got)
	}

	redeemed, err := s.RedeemLinkCode(issued.Code)
	if err != nil {
		t.Fatalf("RedeemLinkCode: %v", err)
	}
	if redeemed.TelegramID != 12345 {
		t.Fatalf("redeemed.TelegramID = %d, want 12345", redeemed.TelegramID)
	}

	acct := s.GetAccount()
	if acct.TelegramID != 12345 || acct.SessionToken != "tok-abc" || acct.Username != "alice" {
		t.Fatalf("account not linked correctly: %+v", acct)
	}
}

func TestRedeemLinkCodeIsSingleUse(t *testing.T) {
	s := newAccountTestStore(t)
	issued, err := s.IssueLinkCode(1, "bob", "tok", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	if _, err := s.RedeemLinkCode(issued.Code); err != nil {
		t.Fatalf("first redeem: %v", err)
	}
	// A replayed code is the core threat: a bearer credential seen once in a
	// bot chat must not link a second client.
	_, err = s.RedeemLinkCode(issued.Code)
	if !errors.Is(err, ErrLinkCodeUsed) {
		t.Fatalf("second redeem err = %v, want ErrLinkCodeUsed", err)
	}
}

func TestRedeemLinkCodeAcceptsNormalizedInput(t *testing.T) {
	s := newAccountTestStore(t)
	issued, err := s.IssueLinkCode(7, "carol", "tok", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	// Users retype codes with dashes and lower case; that must still work.
	messy := strings.ToLower(issued.Code[:4]) + "-" + strings.ToLower(issued.Code[4:])
	if _, err := s.RedeemLinkCode(messy); err != nil {
		t.Fatalf("RedeemLinkCode(%q): %v", messy, err)
	}
	if s.GetAccount().TelegramID != 7 {
		t.Fatal("account not linked after normalized redemption")
	}
}

func TestRedeemLinkCodeExpired(t *testing.T) {
	s := newAccountTestStore(t)
	// Negative TTL would be coerced to the default, so issue with a real TTL
	// and rewrite ExpiresAt into the past to simulate elapsed time.
	issued, err := s.IssueLinkCode(2, "dave", "tok", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	if err := s.Update(func(st *State) error {
		for i := range st.LinkCodes {
			if st.LinkCodes[i].Code == issued.Code {
				st.LinkCodes[i].ExpiresAt = time.Now().UTC().Add(-time.Second)
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	_, err = s.RedeemLinkCode(issued.Code)
	if !errors.Is(err, ErrLinkCodeExpired) {
		t.Fatalf("err = %v, want ErrLinkCodeExpired", err)
	}
	if s.GetAccount().TelegramID != 0 {
		t.Fatal("expired code must not link the account")
	}
}

func TestRedeemLinkCodeUnknown(t *testing.T) {
	s := newAccountTestStore(t)
	_, err := s.RedeemLinkCode("ZZZZ9999")
	if !errors.Is(err, ErrLinkCodeNotFound) {
		t.Fatalf("err = %v, want ErrLinkCodeNotFound", err)
	}
	if _, err := s.RedeemLinkCode(""); !errors.Is(err, ErrLinkCodeNotFound) {
		t.Fatalf("empty input err = %v, want ErrLinkCodeNotFound", err)
	}
}

func TestLinkCodeAttemptCapBurnsCode(t *testing.T) {
	s := newAccountTestStore(t)
	issued, err := s.IssueLinkCode(3, "erin", "tok", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	// Expire it so each redemption fails and increments the counter.
	if err := s.Update(func(st *State) error {
		for i := range st.LinkCodes {
			st.LinkCodes[i].ExpiresAt = time.Now().UTC().Add(-time.Second)
		}
		return nil
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}
	for i := 0; i < MaxLinkCodeAttempts; i++ {
		if _, err := s.RedeemLinkCode(issued.Code); err == nil {
			t.Fatalf("attempt %d unexpectedly succeeded", i)
		}
	}
	// After the cap, the code reports as blocked rather than merely expired —
	// this is what bounds brute force on a short code.
	_, err = s.RedeemLinkCode(issued.Code)
	if !errors.Is(err, ErrLinkCodeAttempts) {
		t.Fatalf("err = %v, want ErrLinkCodeAttempts", err)
	}
}

func TestIssueLinkCodeSupersedesPrevious(t *testing.T) {
	s := newAccountTestStore(t)
	first, err := s.IssueLinkCode(9, "frank", "tok1", time.Minute)
	if err != nil {
		t.Fatalf("first issue: %v", err)
	}
	second, err := s.IssueLinkCode(9, "frank", "tok2", time.Minute)
	if err != nil {
		t.Fatalf("second issue: %v", err)
	}
	if first.Code == second.Code {
		t.Fatal("second issue returned the same code")
	}
	// The stale code from the first bot message must be dead, otherwise a
	// user who requested a new code leaves a valid credential behind.
	if _, err := s.RedeemLinkCode(first.Code); !errors.Is(err, ErrLinkCodeNotFound) {
		t.Fatalf("stale code err = %v, want ErrLinkCodeNotFound", err)
	}
	if _, err := s.RedeemLinkCode(second.Code); err != nil {
		t.Fatalf("current code redeem: %v", err)
	}
}

func TestIssueLinkCodeRequiresTelegramID(t *testing.T) {
	s := newAccountTestStore(t)
	if _, err := s.IssueLinkCode(0, "x", "tok", time.Minute); err == nil {
		t.Fatal("expected error for zero telegram_id")
	}
}

func TestIssueLinkCodeDefaultTTL(t *testing.T) {
	s := newAccountTestStore(t)
	c, err := s.IssueLinkCode(4, "gina", "tok", 0)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	got := c.ExpiresAt.Sub(c.IssuedAt)
	if got != DefaultLinkCodeTTL {
		t.Fatalf("ttl = %v, want %v", got, DefaultLinkCodeTTL)
	}
}

func TestLinkCodePersistsAcrossReopen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "store.json")
	s1, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	issued, err := s1.IssueLinkCode(55, "hugo", "tok", time.Hour)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}
	// The daemon may restart between the bot issuing a code and the user
	// typing it, so codes must survive a reopen.
	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if _, err := s2.RedeemLinkCode(issued.Code); err != nil {
		t.Fatalf("redeem after reopen: %v", err)
	}
	if s2.GetAccount().TelegramID != 55 {
		t.Fatal("account not linked after reopen")
	}
}

func TestPruneLinkCodes(t *testing.T) {
	s := newAccountTestStore(t)
	live, err := s.IssueLinkCode(10, "a", "t", time.Hour)
	if err != nil {
		t.Fatalf("issue live: %v", err)
	}
	spent, err := s.IssueLinkCode(11, "b", "t", time.Hour)
	if err != nil {
		t.Fatalf("issue spent: %v", err)
	}
	if _, err := s.RedeemLinkCode(spent.Code); err != nil {
		t.Fatalf("redeem: %v", err)
	}
	if err := s.PruneLinkCodes(); err != nil {
		t.Fatalf("PruneLinkCodes: %v", err)
	}
	if s.GetLinkCode(spent.Code) != nil {
		t.Fatal("spent code survived prune")
	}
	if s.GetLinkCode(live.Code) == nil {
		t.Fatal("live code was pruned")
	}
}

func TestRedeemLinkCodeConcurrentSingleWinner(t *testing.T) {
	s := newAccountTestStore(t)
	issued, err := s.IssueLinkCode(77, "iris", "tok", time.Minute)
	if err != nil {
		t.Fatalf("IssueLinkCode: %v", err)
	}

	// Two clients racing on the same code must not both link: the code is
	// single-use and the check-then-burn happens inside one atomic update.
	const n = 8
	var wg sync.WaitGroup
	var mu sync.Mutex
	successes := 0
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			if _, err := s.RedeemLinkCode(issued.Code); err == nil {
				mu.Lock()
				successes++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if successes != 1 {
		t.Fatalf("got %d successful redemptions, want exactly 1", successes)
	}
}

// ────────── Payment history ─────────────────────────────────────────

func TestAddPaymentRequiresID(t *testing.T) {
	s := newAccountTestStore(t)
	if err := s.AddPayment(PaymentEntry{Provider: "lava"}); err == nil {
		t.Fatal("expected error for empty payment id")
	}
}

func TestAddPaymentUpdatesInPlace(t *testing.T) {
	s := newAccountTestStore(t)
	created := time.Now().UTC().Add(-time.Hour)
	if err := s.AddPayment(PaymentEntry{
		ID: "inv-1", Provider: "lava", Amount: 199, Currency: "RUB",
		Status: "pending", CreatedAt: created,
	}); err != nil {
		t.Fatalf("AddPayment: %v", err)
	}
	if err := s.AddPayment(PaymentEntry{
		ID: "inv-1", Provider: "lava", Amount: 199, Currency: "RUB",
		Status: "paid", Days: 30, PaidAt: time.Now().UTC(),
	}); err != nil {
		t.Fatalf("AddPayment update: %v", err)
	}

	list := s.ListPayments()
	if len(list) != 1 {
		t.Fatalf("got %d rows, want 1 (status update must not duplicate)", len(list))
	}
	if list[0].Status != "paid" || list[0].Days != 30 {
		t.Fatalf("row not updated: %+v", list[0])
	}
	// CreatedAt must survive the status transition; overwriting it would
	// misreport when the user actually started the payment.
	if !list[0].CreatedAt.Equal(created) {
		t.Fatalf("CreatedAt = %v, want preserved %v", list[0].CreatedAt, created)
	}
}

func TestAddPaymentSameIDDifferentProviderIsDistinct(t *testing.T) {
	s := newAccountTestStore(t)
	for _, p := range []string{"lava", "yookassa"} {
		if err := s.AddPayment(PaymentEntry{ID: "same", Provider: p, Status: "paid"}); err != nil {
			t.Fatalf("AddPayment(%s): %v", p, err)
		}
	}
	// Providers issue IDs independently, so a collision across providers is
	// two different payments, not one.
	if got := len(s.ListPayments()); got != 2 {
		t.Fatalf("got %d rows, want 2", got)
	}
}

func TestListPaymentsNewestFirst(t *testing.T) {
	s := newAccountTestStore(t)
	for _, id := range []string{"a", "b", "c"} {
		if err := s.AddPayment(PaymentEntry{ID: id, Provider: "lava", Status: "paid"}); err != nil {
			t.Fatalf("AddPayment: %v", err)
		}
	}
	list := s.ListPayments()
	if len(list) != 3 || list[0].ID != "c" || list[2].ID != "a" {
		t.Fatalf("unexpected order: %+v", list)
	}
}

func TestPaymentHistoryIsCapped(t *testing.T) {
	s := newAccountTestStore(t)
	total := maxPaymentHistory + 25
	for i := 0; i < total; i++ {
		if err := s.AddPayment(PaymentEntry{
			ID:       "p" + string(rune('a'+i%26)) + strings.Repeat("x", i%5) + itoa(i),
			Provider: "lava", Status: "paid",
		}); err != nil {
			t.Fatalf("AddPayment %d: %v", i, err)
		}
	}
	list := s.ListPayments()
	// The store is a JSON file rewritten on every update; unbounded history
	// would make each write progressively slower.
	if len(list) != maxPaymentHistory {
		t.Fatalf("history size = %d, want cap %d", len(list), maxPaymentHistory)
	}
	// Oldest rows are dropped, newest retained.
	if list[0].ID != "p"+string(rune('a'+(total-1)%26))+strings.Repeat("x", (total-1)%5)+itoa(total-1) {
		t.Fatalf("newest row missing after cap: %+v", list[0])
	}
}

// itoa avoids importing strconv just for test fixtures.
func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}

func TestPaymentsPersistAcrossReopen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "store.json")
	s1, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s1.AddPayment(PaymentEntry{
		ID: "inv-9", Provider: "yookassa", Amount: 349, Currency: "RUB", Status: "paid", Days: 30,
	}); err != nil {
		t.Fatalf("AddPayment: %v", err)
	}
	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	list := s2.ListPayments()
	if len(list) != 1 || list[0].ID != "inv-9" || list[0].Days != 30 {
		t.Fatalf("history did not survive reopen: %+v", list)
	}
}

func TestAddPaymentSetsCreatedAtWhenMissing(t *testing.T) {
	s := newAccountTestStore(t)
	if err := s.AddPayment(PaymentEntry{ID: "z", Provider: "cryptobot", Status: "pending"}); err != nil {
		t.Fatalf("AddPayment: %v", err)
	}
	list := s.ListPayments()
	if len(list) != 1 || list[0].CreatedAt.IsZero() {
		t.Fatalf("CreatedAt not defaulted: %+v", list)
	}
}
