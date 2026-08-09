package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/VlrRbn/kubernetes-gitops-reliability-platform/app/internal/config"
)

type API struct {
	cfg      config.Config
	random   func() float64
	version  string
	commit   string
	requests atomic.Uint64
	errors   atomic.Uint64
}

func New(cfg config.Config, random func() float64, version, commit string) http.Handler {
	api := &API{cfg: cfg, random: random, version: version, commit: commit}

	mux := http.NewServeMux()
	mux.HandleFunc("/", api.root)
	mux.HandleFunc("/healthz", api.health)
	mux.HandleFunc("/readyz", api.ready)
	mux.HandleFunc("/metrics", api.metrics)

	return mux
}

func (a *API) root(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	a.requests.Add(1)
	if a.cfg.Delay > 0 {
		time.Sleep(a.cfg.Delay)
	}

	if a.random() < a.cfg.ErrorRate {
		a.errors.Add(1)
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"status": "injected-error",
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"service": "reliability-demo",
		"status":  "ok",
		"version": a.version,
		"commit":  a.commit,
	})
}

func (a *API) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "healthy"})
}

func (a *API) ready(w http.ResponseWriter, _ *http.Request) {
	if !a.cfg.Ready {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not-ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *API) metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = fmt.Fprintf(w, `# HELP reliability_demo_http_requests_total Requests to the application endpoint.
# TYPE reliability_demo_http_requests_total counter
reliability_demo_http_requests_total %d
# HELP reliability_demo_http_errors_total Injected application errors.
# TYPE reliability_demo_http_errors_total counter
reliability_demo_http_errors_total %d
# HELP reliability_demo_ready Whether the application is configured as ready.
# TYPE reliability_demo_ready gauge
reliability_demo_ready %d
# HELP reliability_demo_configured_delay_milliseconds Configured application delay in milliseconds.
# TYPE reliability_demo_configured_delay_milliseconds gauge
reliability_demo_configured_delay_milliseconds %d
`, a.requests.Load(), a.errors.Load(), boolNumber(a.cfg.Ready), a.cfg.Delay.Milliseconds())
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func boolNumber(value bool) int {
	if value {
		return 1
	}
	return 0
}
