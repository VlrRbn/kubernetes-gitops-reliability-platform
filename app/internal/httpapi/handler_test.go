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
	body := recorder.Body.String()
	for _, metric := range []string{
		`reliability_demo_http_requests_total{code="200"} 1`,
		`reliability_demo_http_request_duration_seconds_count{code="200"} 1`,
		`reliability_demo_build_info{commit="abc123",version="test"} 1`,
	} {
		if !strings.Contains(body, metric) {
			t.Fatalf("metrics do not contain %q: %s", metric, body)
		}
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
	for _, metric := range []string{
		"reliability_demo_http_errors_total 1",
		`reliability_demo_http_requests_total{code="503"} 1`,
		`reliability_demo_http_request_duration_seconds_count{code="503"} 1`,
		"reliability_demo_ready 0",
	} {
		if !strings.Contains(body, metric) {
			t.Fatalf("metrics do not contain %q: %s", metric, body)
		}
	}
}

func TestHandlersUseIsolatedMetricRegistries(t *testing.T) {
	t.Parallel()

	first := New(config.Config{Port: 8080, Ready: true}, func() float64 { return 0.9 }, "first", "111")
	second := New(config.Config{Port: 8080, Ready: true}, func() float64 { return 0.9 }, "second", "222")

	assertStatus(t, first, "/", http.StatusOK)

	recorder := httptest.NewRecorder()
	second.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := recorder.Body.String()
	if !strings.Contains(body, `reliability_demo_http_requests_total{code="200"} 0`) {
		t.Fatalf("second handler inherited metrics from first handler: %s", body)
	}
	if strings.Contains(body, `commit="111"`) {
		t.Fatalf("second handler exposed first handler build identity: %s", body)
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
