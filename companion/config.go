package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Config is read from companion.json sitting next to the executable. A template
// is written on first run so the user just fills in the token + (optionally) the
// WoW client folder.
type Config struct {
	ServerURL   string `json:"server_url"`   // e.g. https://epoglogs.com
	UploadToken string `json:"upload_token"` // minted at <server>/account → companion token
	WoWDir      string `json:"wow_dir"`      // WoW client folder (contains Logs/ and WTF/); auto-detected if empty
	LogName     string `json:"log_name"`     // optional friendly name attached to uploads
	IsPug       bool   `json:"is_pug"`        // mark uploads as PUG runs
}

const defaultServerURL = "https://epoglogs.com"

func defaultConfig() Config {
	return Config{ServerURL: defaultServerURL}
}

func configPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(exe), "companion.json"), nil
}

// loadConfig reads companion.json, creating a template if it does not exist yet.
func loadConfig() (Config, string, error) {
	cfg := defaultConfig()
	path, err := configPath()
	if err != nil {
		return cfg, "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			_ = saveConfig(cfg, path) // best-effort template; absence is non-fatal
			return cfg, path, nil
		}
		return cfg, path, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, path, err
	}
	if cfg.ServerURL == "" {
		cfg.ServerURL = defaultServerURL
	}
	return cfg, path, nil
}

func saveConfig(cfg Config, path string) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
