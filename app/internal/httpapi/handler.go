package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/VlrRbn/kubernetes-gitops-reliability-platform/app/internal/config"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type API struct {
	cfg      config.Config
	random   func() float64
	version  string
	commit   string
	requests *prometheus.CounterVec
	errors   prometheus.Counter
	duration *prometheus.HistogramVec
}

func New(cfg config.Config, random func() float64, version, commit string) http.Handler {
	registry := prometheus.NewRegistry()
	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Namespace: "reliability_demo",
		Subsystem: "http",
		Name:      "requests_total",
		Help:      "Requests to the application endpoint by HTTP status code.",
	}, []string{"code"})
	errors := prometheus.NewCounter(prometheus.CounterOpts{
		Namespace: "reliability_demo",
		Subsystem: "http",
		Name:      "errors_total",
		Help:      "Injected application errors.",
	})
	duration := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "reliability_demo",
		Subsystem: "http",
		Name:      "request_duration_seconds",
		Help:      "Application endpoint request duration by HTTP status code.",
		Buckets:   prometheus.DefBuckets,
	}, []string{"code"})
	ready := prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Namespace: "reliability_demo",
		Name:      "ready",
		Help:      "Whether the application is configured as ready.",
	}, func() float64 { return boolNumber(cfg.Ready) })
	configuredDelay := prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Namespace: "reliability_demo",
		Name:      "configured_delay_milliseconds",
		Help:      "Configured application delay in milliseconds.",
	}, func() float64 { return float64(cfg.Delay.Milliseconds()) })
	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "reliability_demo",
		Name:      "build_info",
		Help:      "Build identity for the running application.",
	}, []string{"commit", "version"})

	for _, code := range []string{"200", "503"} {
		requests.WithLabelValues(code).Add(0)
		duration.WithLabelValues(code)
	}
	buildInfo.WithLabelValues(commit, version).Set(1)
	registry.MustRegister(requests, errors, duration, ready, configuredDelay, buildInfo)

	api := &API{
		cfg:      cfg,
		random:   random,
		version:  version,
		commit:   commit,
		requests: requests,
		errors:   errors,
		duration: duration,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", api.root)
	mux.HandleFunc("/healthz", api.health)
	mux.HandleFunc("/readyz", api.ready)
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))

	return mux
}

func (a *API) root(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	started := time.Now()
	status := http.StatusOK
	defer func() {
		code := strconv.Itoa(status)
		a.requests.WithLabelValues(code).Inc()
		a.duration.WithLabelValues(code).Observe(time.Since(started).Seconds())
	}()

	if a.cfg.Delay > 0 {
		time.Sleep(a.cfg.Delay)
	}

	if a.random() < a.cfg.ErrorRate {
		status = http.StatusServiceUnavailable
		a.errors.Inc()
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

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func boolNumber(value bool) float64 {
	if value {
		return 1.0
	}
	return 0.0
}
