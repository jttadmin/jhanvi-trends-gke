package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// These tests cover request validation, which runs before any database call, so they need no Postgres.
// The SQL itself (reservations, settle) is exercised end to end by tests/functional against a real cluster.
func newTestServer() http.Handler {
	s := &server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	return s.routes()
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestValidationRejectsBadInputBeforeTouchingTheDatabase(t *testing.T) {
	h := newTestServer()
	cases := []struct{ name, method, path, body string }{
		{"stock: non-numeric id", http.MethodGet, "/stock/abc", ""},
		{"set: non-numeric id", http.MethodPut, "/stock/abc", `{"available":1}`},
		{"set: missing available", http.MethodPut, "/stock/1", `{}`},
		{"set: negative", http.MethodPut, "/stock/1", `{"available":-1}`},
		{"set: too large", http.MethodPut, "/stock/1", `{"available":1000001}`},
		{"set: bad json", http.MethodPut, "/stock/1", `nope`},
		{"adjust: zero delta", http.MethodPost, "/stock/1/adjust", `{"delta":0}`},
		{"adjust: huge delta", http.MethodPost, "/stock/1/adjust", `{"delta":1000001}`},
		{"adjust: huge negative", http.MethodPost, "/stock/1/adjust", `{"delta":-1000001}`},
		{"adjust: non-numeric id", http.MethodPost, "/stock/x/adjust", `{"delta":1}`},
		{"delete: non-numeric id", http.MethodDelete, "/stock/x", ""},
		{"reserve: empty body", http.MethodPost, "/reservations", ``},
		{"reserve: no orderRef", http.MethodPost, "/reservations", `{"items":[{"productId":1,"quantity":1}]}`},
		{"reserve: no items", http.MethodPost, "/reservations", `{"orderRef":"o-1","items":[]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if rec := do(h, tc.method, tc.path, tc.body); rec.Code != http.StatusBadRequest {
				t.Fatalf("want 400, got %d (%s)", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestErrorBodyIsJSON(t *testing.T) {
	rec := do(newTestServer(), http.MethodGet, "/stock/abc", "")
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content-type %q", ct)
	}
	if !strings.Contains(rec.Body.String(), `"error":"invalid product id"`) {
		t.Fatalf("body %s", rec.Body.String())
	}
}

func TestHealthz(t *testing.T) {
	if rec := do(newTestServer(), http.MethodGet, "/healthz", ""); rec.Code != http.StatusOK {
		t.Fatalf("healthz: %d", rec.Code)
	}
}

func TestUnknownRouteAndMethod(t *testing.T) {
	h := newTestServer()
	if rec := do(h, http.MethodGet, "/nope", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("want 404, got %d", rec.Code)
	}
	if rec := do(h, http.MethodPatch, "/stock/1", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("want 405, got %d", rec.Code)
	}
}

func TestInstrumentPassesStatusThrough(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /stock/{productId}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusInternalServerError) })
	h := instrument(mux, "inventory-service", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if rec := do(h, http.MethodGet, "/stock/1", ""); rec.Code != http.StatusInternalServerError {
		t.Fatalf("got %d", rec.Code)
	}
	if rec := do(h, http.MethodGet, "/healthz", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("ops paths bypass metrics but are still served by the mux: got %d", rec.Code)
	}
}

func TestHelpers(t *testing.T) {
	if indexSpace("POST /reservations") != 4 || indexSpace("x") != -1 {
		t.Fatal("indexSpace")
	}
	t.Setenv("INV_TEST_VAR", "v")
	if getenv("INV_TEST_VAR", "d") != "v" || getenv("INV_TEST_UNSET", "d") != "d" {
		t.Fatal("getenv")
	}
	t.Setenv("OTEL_SERVICE_NAME", "custom")
	if serviceName("inventory-service") != "custom" {
		t.Fatal("serviceName from env")
	}
}
