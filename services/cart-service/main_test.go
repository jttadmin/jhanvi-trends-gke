package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

// newTestServer runs the real handlers against an in-memory Redis (miniredis).
func newTestServer(t *testing.T) (http.Handler, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	s := &server{rdb: rdb, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	return s.routes(), mr
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

type cartBody struct {
	UserID string `json:"userId"`
	Items  []item `json:"items"`
}

func getCart(t *testing.T, h http.Handler, user string) cartBody {
	t.Helper()
	rec := do(t, h, http.MethodGet, "/cart/"+user, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET cart: status %d", rec.Code)
	}
	var c cartBody
	if err := json.Unmarshal(rec.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestEmptyCart(t *testing.T) {
	h, _ := newTestServer(t)
	c := getCart(t, h, "u1")
	if c.UserID != "u1" || len(c.Items) != 0 {
		t.Fatalf("want empty cart for u1, got %+v", c)
	}
}

func TestAddItemAccumulatesAndSetsTTL(t *testing.T) {
	h, mr := newTestServer(t)
	if rec := do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":3,"quantity":2}`); rec.Code != http.StatusCreated {
		t.Fatalf("add: status %d", rec.Code)
	}
	rec := do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":3,"quantity":1}`)
	var got item
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got.Quantity != 3 {
		t.Fatalf("quantity should accumulate to 3, got %d", got.Quantity)
	}
	if ttl := mr.TTL("cart:u1"); ttl < 29*24*time.Hour {
		t.Fatalf("cart TTL should be ~30 days, got %v", ttl)
	}
}

func TestAddItemValidation(t *testing.T) {
	h, _ := newTestServer(t)
	for _, body := range []string{``, `not json`, `{"productId":0,"quantity":1}`, `{"productId":1,"quantity":0}`, `{"productId":1,"quantity":51}`} {
		if rec := do(t, h, http.MethodPost, "/cart/u1/items", body); rec.Code != http.StatusBadRequest {
			t.Errorf("body %q: want 400, got %d", body, rec.Code)
		}
	}
}

func TestSetItemUpdatesAndZeroRemoves(t *testing.T) {
	h, _ := newTestServer(t)
	do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":5,"quantity":1}`)
	if rec := do(t, h, http.MethodPut, "/cart/u1/items/5", `{"quantity":7}`); rec.Code != http.StatusOK {
		t.Fatalf("set: status %d", rec.Code)
	}
	if c := getCart(t, h, "u1"); len(c.Items) != 1 || c.Items[0].Quantity != 7 {
		t.Fatalf("want quantity 7, got %+v", c.Items)
	}
	do(t, h, http.MethodPut, "/cart/u1/items/5", `{"quantity":0}`)
	if c := getCart(t, h, "u1"); len(c.Items) != 0 {
		t.Fatalf("quantity 0 should remove the line, got %+v", c.Items)
	}
}

func TestSetItemValidation(t *testing.T) {
	h, _ := newTestServer(t)
	cases := map[string]string{"/cart/u1/items/abc": `{"quantity":1}`, "/cart/u1/items/1": `{"quantity":-1}`, "/cart/u1/items/2": `{"quantity":51}`}
	for path, body := range cases {
		if rec := do(t, h, http.MethodPut, path, body); rec.Code != http.StatusBadRequest {
			t.Errorf("%s %s: want 400, got %d", path, body, rec.Code)
		}
	}
}

func TestRemoveAndClear(t *testing.T) {
	h, _ := newTestServer(t)
	do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":1,"quantity":1}`)
	do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":2,"quantity":1}`)
	if rec := do(t, h, http.MethodDelete, "/cart/u1/items/1", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("remove: status %d", rec.Code)
	}
	if c := getCart(t, h, "u1"); len(c.Items) != 1 || c.Items[0].ProductID != 2 {
		t.Fatalf("want only product 2 left, got %+v", c.Items)
	}
	if rec := do(t, h, http.MethodDelete, "/cart/u1", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("clear: status %d", rec.Code)
	}
	if c := getCart(t, h, "u1"); len(c.Items) != 0 {
		t.Fatalf("cart should be empty after clear, got %+v", c.Items)
	}
}

func TestCartsAreIsolatedPerUser(t *testing.T) {
	h, _ := newTestServer(t)
	do(t, h, http.MethodPost, "/cart/u1/items", `{"productId":1,"quantity":1}`)
	if c := getCart(t, h, "u2"); len(c.Items) != 0 {
		t.Fatalf("u2 must not see u1's cart, got %+v", c.Items)
	}
}

func TestCorruptFieldsAreIgnored(t *testing.T) {
	h, mr := newTestServer(t)
	mr.HSet("cart:u1", "abc", "2")
	mr.HSet("cart:u1", "4", "-1")
	mr.HSet("cart:u1", "6", "2")
	if c := getCart(t, h, "u1"); len(c.Items) != 1 || c.Items[0].ProductID != 6 {
		t.Fatalf("only the valid line should be returned, got %+v", c.Items)
	}
}

func TestRedisDownGives503(t *testing.T) {
	h, mr := newTestServer(t)
	mr.Close()
	for _, tc := range []struct{ method, path, body string }{
		{http.MethodGet, "/cart/u1", ""},
		{http.MethodPost, "/cart/u1/items", `{"productId":1,"quantity":1}`},
		{http.MethodPut, "/cart/u1/items/1", `{"quantity":2}`},
		{http.MethodDelete, "/cart/u1/items/1", ""},
		{http.MethodDelete, "/cart/u1", ""},
		{http.MethodGet, "/readyz", ""},
	} {
		if rec := do(t, h, tc.method, tc.path, tc.body); rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s %s: want 503, got %d", tc.method, tc.path, rec.Code)
		}
	}
}

func TestHealthAndReady(t *testing.T) {
	h, _ := newTestServer(t)
	if rec := do(t, h, http.MethodGet, "/healthz", ""); rec.Code != http.StatusOK {
		t.Fatalf("healthz: %d", rec.Code)
	}
	if rec := do(t, h, http.MethodGet, "/readyz", ""); rec.Code != http.StatusOK {
		t.Fatalf("readyz: %d", rec.Code)
	}
}

func TestInstrumentLabelsRoutePattern(t *testing.T) {
	s := &server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /cart/{userId}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	h := instrument(mux, "cart-service", s.log)
	if rec := do(t, h, http.MethodGet, "/cart/u1", ""); rec.Code != http.StatusTeapot {
		t.Fatalf("instrumented handler should pass the status through, got %d", rec.Code)
	}
	if rec := do(t, h, http.MethodGet, "/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("unmatched route: want 404, got %d", rec.Code)
	}
}

func TestHelpers(t *testing.T) {
	if indexSpace("GET /cart/{userId}") != 3 || indexSpace("nospace") != -1 {
		t.Fatal("indexSpace")
	}
	t.Setenv("CART_TEST_VAR", "x")
	if getenv("CART_TEST_VAR", "d") != "x" || getenv("CART_TEST_UNSET", "d") != "d" {
		t.Fatal("getenv")
	}
	t.Setenv("OTEL_SERVICE_NAME", "")
	if serviceName("cart-service") != "cart-service" {
		t.Fatal("serviceName default")
	}
	if newLogger("cart-service") == nil {
		t.Fatal("newLogger")
	}
}
