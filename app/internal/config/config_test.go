package config

import (
	"testing"
	"time"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadDefaults(t *testing.T) {
	t.Parallel()

	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.Port != 8080 || cfg.Delay != 0 || cfg.ErrorRate != 0 || !cfg.Ready {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestLoadFaultConfiguration(t *testing.T) {
	t.Parallel()

	cfg, err := Load(env(map[string]string{
		"PORT":           "9090",
		"APP_DELAY_MS":   "250",
		"APP_ERROR_RATE": "0.25",
		"APP_READY":      "false",
	}))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.Port != 9090 || cfg.Delay != 250*time.Millisecond || cfg.ErrorRate != 0.25 || cfg.Ready {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestLoadRejectsUnsafeValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		values map[string]string
	}{
		{name: "invalid port", values: map[string]string{"PORT": "0"}},
		{name: "non numeric port", values: map[string]string{"PORT": "http"}},
		{name: "negative delay", values: map[string]string{"APP_DELAY_MS": "-1"}},
		{name: "excessive delay", values: map[string]string{"APP_DELAY_MS": "60001"}},
		{name: "negative error rate", values: map[string]string{"APP_ERROR_RATE": "-0.1"}},
		{name: "excessive error rate", values: map[string]string{"APP_ERROR_RATE": "1.1"}},
		{name: "invalid readiness", values: map[string]string{"APP_READY": "sometimes"}},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if _, err := Load(env(test.values)); err == nil {
				t.Fatal("Load() error = nil, want validation error")
			}
		})
	}
}
