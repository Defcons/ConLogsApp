// ConLogs companion — tails WoWCombatLog.txt and streams it to epoglogs live,
// then auto-uploads ConLogs-Epoch gear data when a raid session ends.
//
// MVP: dependency-free console app. A tray/GUI wrapper can be layered on top of
// the watcher core later without touching the streaming logic.
package main

import (
	"bytes"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	pollInterval = 2 * time.Second // how often we check the log for new bytes
	idleFinish   = 5 * time.Minute // finalize a session after this much inactivity
)

// maxChunkBytes caps each /append request. A var (not const) so tests can shrink
// it to exercise the chunk-splitting path without generating multi-MB fixtures.
var maxChunkBytes = 4 * 1024 * 1024

func main() {
	log.SetFlags(log.Ltime)

	cfg, cfgPath, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}
	log.Printf("ConLogs companion — config: %s", cfgPath)

	if cfg.UploadToken == "" {
		log.Printf("No upload_token set.")
		log.Printf("  1) Sign in at %s and create a Companion token on your account page.", cfg.ServerURL)
		log.Printf("  2) Paste it into %q in %s", "upload_token", cfgPath)
		log.Printf("  3) Restart this app.")
		pause()
		return
	}

	logPath := resolveCombatLog(cfg.WoWDir)
	if logPath == "" {
		log.Printf("Could not locate WoWCombatLog.txt.")
		log.Printf("Set %q in %s to your WoW client folder (the one that contains the Logs and WTF folders).", "wow_dir", cfgPath)
		pause()
		return
	}
	log.Printf("Watching: %s", logPath)
	log.Printf("Reminder: enable Advanced Combat Logging in-game and type /combatlog before pulling.")

	w := &watcher{
		cfg:     cfg,
		client:  NewClient(cfg.ServerURL, cfg.UploadToken),
		logPath: logPath,
	}
	// Start at the current end of file so we only stream combat that happens
	// from now on (WoW appends across sessions; we don't want to re-upload old raids).
	if fi, err := os.Stat(logPath); err == nil {
		w.offset = fi.Size()
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	log.Printf("Ready. Streaming will begin automatically when combat is logged.")
	for {
		select {
		case <-ticker.C:
			w.tick()
		case <-stop:
			log.Printf("Shutting down…")
			w.finishIfOpen("shutdown")
			return
		}
	}
}

type watcher struct {
	cfg     Config
	client  *Client
	logPath string

	offset    int64     // bytes of the file already consumed
	partial   []byte    // unsent bytes (trailing incomplete line + anything held back after a send failure)
	sessionID string    // "" when no session is open
	lastData  time.Time // last successful append
}

func (w *watcher) tick() {
	fi, err := os.Stat(w.logPath)
	if err != nil {
		return // file might be temporarily gone (client restart) — try again next tick
	}
	size := fi.Size()
	if size < w.offset {
		// File shrank → deleted & recreated by the client. Restart from the top.
		log.Printf("Combat log reset detected; restarting from start of file.")
		w.offset = 0
		w.partial = nil
	}
	if size > w.offset {
		if err := w.readNew(size); err != nil {
			log.Printf("read error: %v", err)
			return
		}
	}

	// Send all complete lines; keep the trailing partial line buffered.
	if idx := bytes.LastIndexByte(w.partial, '\n'); idx >= 0 {
		complete := w.partial[:idx+1]
		remainder := append([]byte(nil), w.partial[idx+1:]...)
		if err := w.send(complete); err != nil {
			log.Printf("stream error (will retry): %v", err)
			return // leave w.partial intact so the same bytes retry next tick
		}
		w.partial = remainder
	}

	if w.sessionID != "" && time.Since(w.lastData) > idleFinish {
		w.finishIfOpen("no combat for 5 minutes")
	}
}

// readNew reads bytes [offset, size) and appends them to the unsent buffer.
func (w *watcher) readNew(size int64) error {
	f, err := os.Open(w.logPath)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Seek(w.offset, io.SeekStart); err != nil {
		return err
	}
	buf := make([]byte, size-w.offset)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return err
	}
	w.offset += int64(n)
	w.partial = append(w.partial, buf[:n]...)
	return nil
}

// send opens a session on demand and streams data in <=maxChunkBytes pieces,
// always cutting on newline boundaries so a line is never split across chunks.
func (w *watcher) send(data []byte) error {
	if w.sessionID == "" {
		sid, err := w.client.StartSession(filepath.Base(w.logPath), w.cfg.LogName, w.cfg.IsPug)
		if err != nil {
			return err
		}
		w.sessionID = sid
		log.Printf("Live session started (id %s) — streaming…", sid)
	}
	for len(data) > 0 {
		chunk := data
		if len(chunk) > maxChunkBytes {
			cut := bytes.LastIndexByte(chunk[:maxChunkBytes], '\n')
			if cut < 0 {
				cut = maxChunkBytes - 1 // pathological: a single line > maxChunkBytes
			}
			chunk = chunk[:cut+1]
		}
		if err := w.client.AppendChunk(w.sessionID, chunk); err != nil {
			return err
		}
		data = data[len(chunk):]
	}
	w.lastData = time.Now()
	return nil
}

func (w *watcher) finishIfOpen(reason string) {
	if w.sessionID == "" {
		return
	}
	// Flush any buffered complete lines first so the finalized log isn't missing
	// the tail of the fight.
	if idx := bytes.LastIndexByte(w.partial, '\n'); idx >= 0 {
		if err := w.send(w.partial[:idx+1]); err != nil {
			log.Printf("final flush error: %v", err)
		} else {
			w.partial = append([]byte(nil), w.partial[idx+1:]...)
		}
	}
	sid := w.sessionID
	w.sessionID = ""
	log.Printf("Finalizing session %s (%s)…", sid, reason)
	logID, err := w.client.FinishSession(sid)
	if err != nil {
		log.Printf("finish failed: %v", err)
		return
	}
	log.Printf("Log uploaded → %s/log/%d", strings.TrimRight(w.cfg.ServerURL, "/"), logID)
	w.uploadArmory()
}

func (w *watcher) uploadArmory() {
	path := findEpogArmory(w.cfg.WoWDir)
	if path == "" {
		log.Printf("Gear SavedVariables not found — skipping gear upload. (Install the ConLogs-Epoch addon to include equipment.)")
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("read armory file: %v", err)
		return
	}
	if err := w.client.UploadArmory(data); err != nil {
		log.Printf("armory upload failed: %v", err)
		return
	}
	log.Printf("Equipment data uploaded (%s).", filepath.Base(path))
}

// ── Path resolution ──────────────────────────────────────────────────────────

// resolveCombatLog returns the path to WoWCombatLog.txt, or "" if not found.
func resolveCombatLog(wowDir string) string {
	candidates := []string{}
	if wowDir != "" {
		candidates = append(candidates, filepath.Join(wowDir, "Logs", "WoWCombatLog.txt"))
	}
	for _, base := range autoDetectBases() {
		candidates = append(candidates, filepath.Join(base, "Logs", "WoWCombatLog.txt"))
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}

// findEpogArmory returns the most recently modified gear SavedVariables file under
// the WoW client's account-level SavedVariables, or "" if none is found. The addon
// was rebranded EpogArmory → ConLogs-Epoch, so we look for the new filename first
// and fall back to the legacy one for users still on the old addon.
func findEpogArmory(wowDir string) string {
	bases := []string{}
	if wowDir != "" {
		bases = append(bases, wowDir)
	}
	bases = append(bases, autoDetectBases()...)

	savedVarNames := []string{"ConLogs-Epoch.lua", "EpogArmory.lua"}
	var newest string
	var newestTime time.Time
	for _, base := range bases {
		for _, name := range savedVarNames {
			matches, _ := filepath.Glob(filepath.Join(base, "WTF", "Account", "*", "SavedVariables", name))
			for _, m := range matches {
				if fi, err := os.Stat(m); err == nil && fi.ModTime().After(newestTime) {
					newest, newestTime = m, fi.ModTime()
				}
			}
		}
	}
	return newest
}

// autoDetectBases returns best-effort guesses for the Ascension/Project Epoch
// client root. Users with a non-standard install set wow_dir in companion.json.
func autoDetectBases() []string {
	var out []string
	rel := filepath.Join("Ascension Launcher", "resources", "epoch_live")
	seeds := []string{}
	if v := os.Getenv("LOCALAPPDATA"); v != "" {
		seeds = append(seeds, v)
	}
	if v := os.Getenv("ProgramData"); v != "" {
		seeds = append(seeds, v)
	}
	if v := os.Getenv("USERPROFILE"); v != "" {
		seeds = append(seeds, v)
	}
	seeds = append(seeds, `C:\`, `D:\`)
	for _, s := range seeds {
		out = append(out, filepath.Join(s, rel))
	}
	sort.Strings(out)
	return out
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

// pause keeps the console window open so a double-click user can read the message.
func pause() {
	log.Printf("Press Enter to exit…")
	_, _ = io.ReadFull(os.Stdin, make([]byte, 1))
}
