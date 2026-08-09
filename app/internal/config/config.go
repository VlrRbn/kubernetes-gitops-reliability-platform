package config

import (
	"fmt"
	"strconv"
	"time"
)

const (
	defaultPort       = 8080
	maxDelayMillis    = 60_000
	defaultErrorRate  = 0.0
	defaultReadyState = true
)

// Config contains the intentionally small runtime and fault-injection contract.
type Config struct {
	Port      int
	Delay     time.Duration
	ErrorRate float64
	Ready     bool
}

// Load reads configuration through getenv so tests do not mutate process state.
func Load(getenv func(string) string) (Config, error) {
	cfg := Config{
		Port:      defaultPort,
		ErrorRate: defaultErrorRate,
		Ready:     defaultReadyState,
	}

	if raw := getenv("PORT"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 || value > 65_535 {
			return Config{}, fmt.Errorf("PORT must be an integer between 1 and 65535")
		}
		cfg.Port = value
	}

	if raw := getenv("APP_DELAY_MS"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || value > maxDelayMillis {
			return Config{}, fmt.Errorf("APP_DELAY_MS must be an integer between 0 and %d", maxDelayMillis)
		}
		cfg.Delay = time.Duration(value) * time.Millisecond
	}

	if raw := getenv("APP_ERROR_RATE"); raw != "" {
		value, err := strconv.ParseFloat(raw, 64)
		if err != nil || value < 0 || value > 1 {
			return Config{}, fmt.Errorf("APP_ERROR_RATE must be a number between 0 and 1")
		}
		cfg.ErrorRate = value
	}

	if raw := getenv("APP_READY"); raw != "" {
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return Config{}, fmt.Errorf("APP_READY must be true or false")
		}
		cfg.Ready = value
	}

	return cfg, nil
}
