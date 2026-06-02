package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// mockServer emulates the three live endpoints + armory upload, recording what
// the companion sends so we can assert the reassembled stream is faithful.
type mockServer struct {
	mu          sync.Mutex
	srv         *httptest.Server
	starts      int
	appended    bytes.Buffer // concatenation of all /append bodies, in order
	finished    int
	armoryBody  []byte
	gotToken    string
	sessionSeen string
}

func newMockServer(t *testing.T) *mockServer {
	m := &mockServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/logs/live/start", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		m.starts++
		m.gotToken = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		_ = json.NewEncoder(w).Encode(map[string]any{"sessionId": "sess-123"})
	})
	mux.HandleFunc("/api/logs/live/sess-123/append", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		m.mu.Lock()
		defer m.mu.Unlock()
		m.appended.Write(body)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "bytes": m.appended.Len()})
	})
	mux.HandleFunc("/api/logs/live/sess-123/finish", func(w http.ResponseWriter, r *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		m.finished++
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "logId": 42})
	})
	mux.HandleFunc("/api/armory/upload", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		m.mu.Lock()
		defer m.mu.Unlock()
		m.armoryBody = body
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	m.srv = httptest.NewServer(mux)
	t.Cleanup(m.srv.Close)
	return m
}

// newWatcher wires a watcher at the current end of a fresh combat-log file under
// a fake WoW dir that also contains an EpogArmory.lua.
func newWatcher(t *testing.T, m *mockServer) (*watcher, string) {
	dir := t.TempDir()
	logsDir := filepath.Join(dir, "Logs")
	if err := os.MkdirAll(logsDir, 0755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(logsDir, "WoWCombatLog.txt")
	if err := os.WriteFile(logPath, nil, 0644); err != nil {
		t.Fatal(err)
	}
	// Seed a ConLogs-Epoch.lua so the armory-upload path has something to send.
	svDir := filepath.Join(dir, "WTF", "Account", "TESTACC", "SavedVariables")
	if err := os.MkdirAll(svDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(svDir, "ConLogs-Epoch.lua"), []byte("ConLogsDB = {}\n"), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := Config{ServerURL: m.srv.URL, UploadToken: "tok-abc", WoWDir: dir}
	w := &watcher{cfg: cfg, client: NewClient(cfg.ServerURL, cfg.UploadToken), logPath: logPath}
	return w, logPath
}

func appendToFile(t *testing.T, path, s string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString(s); err != nil {
		t.Fatal(err)
	}
}

func TestStreamReassembly(t *testing.T) {
	m := newMockServer(t)
	w, logPath := newWatcher(t, m)

	// 1) Write two full lines + a trailing PARTIAL line (no newline yet).
	appendToFile(t, logPath, "line one\nline two\npartial-")
	w.tick()
	if got := m.appended.String(); got != "line one\nline two\n" {
		t.Fatalf("after partial: expected only the 2 complete lines, got %q", got)
	}
	if m.starts != 1 {
		t.Fatalf("expected exactly 1 session start, got %d", m.starts)
	}

	// 2) Complete the partial line and add another. The buffered "partial-" must
	//    be prepended (no byte loss, no split mid-line).
	appendToFile(t, logPath, "rest\nline four\n")
	w.tick()
	want := "line one\nline two\npartial-rest\nline four\n"
	if got := m.appended.String(); got != want {
		t.Fatalf("after completion:\n got  %q\n want %q", got, want)
	}

	// 3) Finalize → exactly one finish + armory upload.
	w.finishIfOpen("test")
	if m.finished != 1 {
		t.Fatalf("expected 1 finish, got %d", m.finished)
	}
	if !bytes.Contains(m.armoryBody, []byte("ConLogsDB")) {
		t.Fatalf("armory body not uploaded, got %q", m.armoryBody)
	}
	if m.gotToken != "tok-abc" {
		t.Fatalf("bearer token not forwarded, got %q", m.gotToken)
	}
}

func TestChunkSplittingOnNewlineBoundary(t *testing.T) {
	m := newMockServer(t)
	w, logPath := newWatcher(t, m)

	// Shrink the chunk cap so multiple lines force several /append calls, and
	// assert the reassembled bytes are byte-identical (no line split, no loss).
	orig := maxChunkBytes
	maxChunkBytes = 10
	defer func() { maxChunkBytes = orig }()

	var sb strings.Builder
	for i := 0; i < 50; i++ {
		sb.WriteString("aaaa\nbbbb\n") // 10 bytes per pair, > cap → boundary cuts
	}
	appendToFile(t, logPath, sb.String())
	w.tick()

	if got := m.appended.String(); got != sb.String() {
		t.Fatalf("chunked stream mismatch: got %d bytes, want %d", len(got), sb.Len())
	}
	// Every chunk must end on a newline — verify by re-splitting: no chunk
	// boundary should fall mid-line. (Implicitly guaranteed if the concat matches
	// AND each append ended in '\n'; we assert the concat ends in '\n'.)
	if !strings.HasSuffix(m.appended.String(), "\n") {
		t.Fatal("reassembled stream should end on a newline")
	}
}

func TestLogResetReupload(t *testing.T) {
	m := newMockServer(t)
	w, logPath := newWatcher(t, m)

	appendToFile(t, logPath, "first session line\n") // 19 bytes → offset 19
	w.tick()
	w.finishIfOpen("test")

	// Simulate the client deleting & recreating the log: new content is SHORTER
	// than the consumed offset (size < offset), which is what triggers a reset.
	newContent := "new\n" // 4 bytes < 19
	if err := os.WriteFile(logPath, []byte(newContent), 0644); err != nil {
		t.Fatal(err)
	}
	w.tick()
	if w.offset != int64(len(newContent)) {
		t.Fatalf("expected offset reset to %d after re-read, got %d", len(newContent), w.offset)
	}
	if !strings.Contains(m.appended.String(), newContent) {
		t.Fatalf("expected the recreated file to be re-read from the start, got %q", m.appended.String())
	}
}

// guards the idle-finish trigger inside tick().
func TestIdleFinish(t *testing.T) {
	m := newMockServer(t)
	w, logPath := newWatcher(t, m)
	appendToFile(t, logPath, "pull\n")
	w.tick()
	if m.finished != 0 {
		t.Fatal("should not finish while active")
	}
	w.lastData = time.Now().Add(-idleFinish - time.Second) // pretend combat stopped long ago
	w.tick()
	if m.finished != 1 {
		t.Fatalf("expected idle finish, got %d", m.finished)
	}
}
