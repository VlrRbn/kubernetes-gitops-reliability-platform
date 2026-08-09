package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/VlrRbn/kubernetes-gitops-reliability-platform/app/internal/config"
)

func TestHealthyApplication(t *testing.T) {
	t.Parallel()

	handler := New(config.Config{Port: 8080, Ready: true}, func() float64 { return 0.9 }, "test", "abc123")

	assertStatus(t, handler, "/", http.StatusOK)
	assertStatus(t, handler, "/healthz", http.StatusOK)
	assertStatus(t, handler, "/readyz", http.StatusOK)
	assertStatus(t, handler, "/missing", http.StatusNotFound)

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if !strings.Contains(recorder.Body.String(), "reliability_demo_http_requests_total 1") {
		t.Fatalf("metrics do not contain request count: %s", recorder.Body.String())
	}
}

func TestFaultModes(t *testing.T) {
	t.Parallel()

	handler := New(config.Config{
		Port:      8080,
		Ready:     false,
		ErrorRate: 1,
		Delay:     time.Millisecond,
	}, func() float64 { return 0 }, "test", "abc123")

	assertStatus(t, handler, "/", http.StatusServiceUnavailable)
	assertStatus(t, handler, "/healthz", http.StatusOK)
	assertStatus(t, handler, "/readyz", http.StatusServiceUnavailable)

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := recorder.Body.String()
	if !strings.Contains(body, "reliability_demo_http_errors_total 1") ||
		!strings.Contains(body, "reliability_demo_ready 0") {
		t.Fatalf("metrics do not expose fault state: %s", body)
	}
}

func assertStatus(t *testing.T, handler http.Handler, path string, want int) {
	t.Helper()
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
	if recorder.Code != want {
		t.Fatalf("GET %s status = %d, want %d; body=%s", path, recorder.Code, want, recorder.Body.String())
	}
}
