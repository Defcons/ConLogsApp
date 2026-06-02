package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client talks to the epoglogs live-session + armory APIs. Auth is the personal
// upload token, sent as a Bearer header on every request.
type Client struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

func NewClient(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 120 * time.Second},
	}
}

func (c *Client) do(method, path, contentType string, body []byte) ([]byte, int, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.BaseURL+path, rdr)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return respBody, resp.StatusCode, nil
}

type startResp struct {
	SessionID string `json:"sessionId"`
	Error     string `json:"error"`
}

// StartSession opens a live session and returns its id.
func (c *Client) StartSession(fileName, logName string, isPug bool) (string, error) {
	payload, _ := json.Marshal(map[string]any{
		"fileName": fileName,
		"logName":  logName,
		"isPug":    isPug,
	})
	body, code, err := c.do("POST", "/api/logs/live/start", "application/json", payload)
	if err != nil {
		return "", err
	}
	var r startResp
	_ = json.Unmarshal(body, &r)
	if code != 200 || r.SessionID == "" {
		return "", fmt.Errorf("HTTP %d: %s", code, msgOr(r.Error, body))
	}
	return r.SessionID, nil
}

// AppendChunk streams a slice of raw combat-log text to an open session.
func (c *Client) AppendChunk(sessionID string, chunk []byte) error {
	body, code, err := c.do("POST", "/api/logs/live/"+sessionID+"/append", "text/plain", chunk)
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("HTTP %d: %s", code, msgOr("", body))
	}
	return nil
}

type finishResp struct {
	OK    bool   `json:"ok"`
	LogID int    `json:"logId"`
	Error string `json:"error"`
}

// FinishSession finalizes a session and returns the new public log id.
func (c *Client) FinishSession(sessionID string) (int, error) {
	body, code, err := c.do("POST", "/api/logs/live/"+sessionID+"/finish", "", nil)
	if err != nil {
		return 0, err
	}
	var r finishResp
	_ = json.Unmarshal(body, &r)
	if code != 200 || !r.OK {
		return 0, fmt.Errorf("HTTP %d: %s", code, msgOr(r.Error, body))
	}
	return r.LogID, nil
}

// UploadArmory posts the raw EpogArmory.lua SavedVariables file.
func (c *Client) UploadArmory(lua []byte) error {
	body, code, err := c.do("POST", "/api/armory/upload", "text/plain", lua)
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("HTTP %d: %s", code, msgOr("", body))
	}
	return nil
}

// msgOr prefers an explicit error string, falling back to a truncated raw body.
func msgOr(explicit string, raw []byte) string {
	if explicit != "" {
		return explicit
	}
	s := string(raw)
	if len(s) > 200 {
		return s[:200]
	}
	return s
}
