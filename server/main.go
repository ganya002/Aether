package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
)

const (
	port    = ":7391"
	apiPort = ":7392"
)

type session struct {
	id     string
	cmd    *exec.Cmd
	master *os.File
	mu     sync.Mutex
	scroll []byte
	cols   int
	rows   int
	cwd    string
	title  string
	state  string
	msg    string
	subs   map[chan []byte]struct{}
}

type hub struct {
	mu       sync.Mutex
	token    string
	sessions map[string]*session
}

func main() {
	token := loadToken()
	h := &hub{token: token, sessions: map[string]*session{}}
	go h.serveAPI()
	ln, err := net.Listen("tcp", port)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("aether-sessiond listening on %s", port)
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go h.handle(conn)
	}
}

func loadToken() string {
	path := "/var/lib/aether/token"
	if b, err := os.ReadFile(path); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	buf := make([]byte, 24)
	_, _ = rand.Read(buf)
	token := hex.EncodeToString(buf)
	_ = os.MkdirAll("/var/lib/aether", 0o700)
	_ = os.WriteFile(path, []byte(token+"\n"), 0o600)
	return token
}

type lockedConn struct {
	c  net.Conn
	mu sync.Mutex
}

func (l *lockedConn) write(msg map[string]any) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return writeFrame(l.c, msg)
}

func (h *hub) handle(conn net.Conn) {
	defer conn.Close()
	link := &lockedConn{c: conn}
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	hello, err := readFrame(conn)
	if err != nil {
		return
	}
	if hello["type"] != "hello" || hello["token"] != h.token {
		_ = link.write(map[string]any{"type": "error", "message": "unauthorized"})
		return
	}
	_ = conn.SetDeadline(time.Time{})
	_ = link.write(map[string]any{"type": "helloOk", "version": 1})
	var subs []struct {
		s  *session
		ch chan []byte
	}
	defer func() {
		for _, item := range subs {
			item.s.unsubscribe(item.ch)
		}
	}()
	for {
		msg, err := readFrame(conn)
		if err != nil {
			return
		}
		switch msg["type"] {
		case "create":
			s := h.create(str(msg, "cwd"), intNum(msg, "cols"), intNum(msg, "rows"), str(msg, "command"))
			if s == nil {
				_ = link.write(map[string]any{"type": "error", "message": "could not start a session"})
				continue
			}
			ch := s.subscribe()
			subs = append(subs, struct {
				s  *session
				ch chan []byte
			}{s, ch})
			go pump(link, s.id, ch)
			_ = link.write(map[string]any{"type": "created", "id": s.id, "title": s.title})
			s.sendScroll(link)
		case "attach":
			s := h.get(str(msg, "id"))
			if s == nil {
				_ = link.write(map[string]any{"type": "error", "message": "no such session"})
				continue
			}
			s.resize(intNum(msg, "cols"), intNum(msg, "rows"))
			ch := s.subscribe()
			subs = append(subs, struct {
				s  *session
				ch chan []byte
			}{s, ch})
			go pump(link, s.id, ch)
			_ = link.write(map[string]any{"type": "attached", "id": s.id, "title": s.title, "state": s.state, "msg": s.msg})
			s.sendScroll(link)
		case "input":
			if s := h.get(str(msg, "id")); s != nil {
				if raw, err := base64.StdEncoding.DecodeString(str(msg, "data")); err == nil {
					s.write(raw)
				}
			}
		case "resize":
			if s := h.get(str(msg, "id")); s != nil {
				s.resize(intNum(msg, "cols"), intNum(msg, "rows"))
			}
		case "list":
			_ = link.write(map[string]any{"type": "sessions", "items": h.list()})
		case "close":
			h.close(str(msg, "id"))
		case "detach":
			// The connection close drops subscriptions. Nothing else to do.
		default:
			_ = writeFrame(conn, map[string]any{"type": "error", "message": "unknown message"})
		}
	}
}

func pump(conn *lockedConn, id string, sub chan []byte) {
	for chunk := range sub {
		if chunk == nil {
			return
		}
		if chunk[0] == 1 {
			let := string(chunk[1:])
			state, msg, _ := strings.Cut(let, "\n")
			if err := conn.write(map[string]any{"type": "status", "id": id, "state": state, "msg": msg}); err != nil {
				return
			}
			continue
		}
		if err := conn.write(map[string]any{
			"type": "output",
			"id":   id,
			"data": base64.StdEncoding.EncodeToString(chunk[1:]),
		}); err != nil {
			return
		}
	}
}

func (h *hub) create(cwd string, cols, rows int, command string) *session {
	if cwd == "" {
		cwd, _ = os.UserHomeDir()
	}
	if cols < 20 {
		cols = 80
	}
	if rows < 5 {
		rows = 24
	}
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/bash"
	}
	cmd := exec.Command(shell, "-l")
	if strings.TrimSpace(command) != "" {
		cmd = exec.Command(shell, "-lc", command)
	}
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "TERM_PROGRAM=Aether")
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil
	}
	id := newID()
	s := &session{
		id: id, cmd: cmd, master: master, cols: cols, rows: rows, cwd: cwd,
		title: "shell", state: "idle", subs: map[chan []byte]struct{}{},
	}
	h.mu.Lock()
	h.sessions[id] = s
	h.mu.Unlock()
	go s.readLoop()
	go func() {
		_ = cmd.Wait()
		s.mu.Lock()
		s.state = "done"
		s.msg = "exited"
		s.mu.Unlock()
		s.broadcastStatus("done", "exited")
		s.broadcast(nil)
		h.mu.Lock()
		delete(h.sessions, id)
		h.mu.Unlock()
	}()
	return s
}

func (s *session) readLoop() {
	buf := make([]byte, 32*1024)
	var pending []byte
	for {
		n, err := s.master.Read(buf)
		if n > 0 {
			pending = append(pending, buf[:n]...)
			clean, reports, query := takeStatus(&pending)
			if query {
				_, _ = s.master.Write([]byte("\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\"))
			}
			if len(clean) > 0 {
				s.mu.Lock()
				s.scroll = append(s.scroll, clean...)
				if len(s.scroll) > 1<<20 {
					s.scroll = append([]byte(nil), s.scroll[len(s.scroll)-1<<20:]...)
				}
				s.mu.Unlock()
				s.broadcast(clean)
			}
			for _, report := range reports {
				s.mu.Lock()
				s.state = report.state
				s.msg = report.msg
				if report.app != "" {
					s.title = report.app
				}
				s.mu.Unlock()
				s.broadcastStatus(report.state, report.msg)
			}
		}
		if err != nil {
			return
		}
	}
}

func (s *session) write(p []byte) {
	_, _ = s.master.Write(p)
}

func (s *session) resize(cols, rows int) {
	if cols < 2 || rows < 2 {
		return
	}
	s.mu.Lock()
	s.cols, s.rows = cols, rows
	s.mu.Unlock()
	_ = pty.Setsize(s.master, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

func (s *session) subscribe() chan []byte {
	ch := make(chan []byte, 32)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

func (s *session) unsubscribe(ch chan []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.subs[ch]; ok {
		delete(s.subs, ch)
		close(ch)
	}
}

func (s *session) subscribers() []chan []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	chans := make([]chan []byte, 0, len(s.subs))
	for ch := range s.subs {
		chans = append(chans, ch)
	}
	return chans
}

func (s *session) broadcastStatus(state, msg string) {
	body := append([]byte{1}, []byte(state+"\n"+msg)...)
	for _, ch := range s.subscribers() {
		ch <- body
	}
}

func (s *session) broadcast(p []byte) {
	if p == nil {
		s.mu.Lock()
		for ch := range s.subs {
			close(ch)
			delete(s.subs, ch)
		}
		s.mu.Unlock()
		return
	}
	msg := append([]byte{0}, p...)
	for _, ch := range s.subscribers() {
		ch <- msg
	}
}

func (s *session) sendScroll(conn *lockedConn) {
	s.mu.Lock()
	scroll := append([]byte(nil), s.scroll...)
	s.mu.Unlock()
	if len(scroll) == 0 {
		return
	}
	_ = conn.write(map[string]any{
		"type": "output",
		"id":   s.id,
		"data": base64.StdEncoding.EncodeToString(scroll),
	})
}

func (h *hub) get(id string) *session {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessions[id]
}

func (h *hub) close(id string) {
	s := h.get(id)
	if s == nil {
		return
	}
	_ = s.master.Close()
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	h.mu.Lock()
	delete(h.sessions, id)
	h.mu.Unlock()
}

func (h *hub) list() []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	items := make([]map[string]any, 0, len(h.sessions))
	for _, s := range h.sessions {
		s.mu.Lock()
		items = append(items, map[string]any{
			"id": s.id, "title": s.title, "cwd": s.cwd, "state": s.state, "msg": s.msg,
		})
		s.mu.Unlock()
	}
	return items
}

type report struct {
	state string
	msg   string
	app   string
}

func takeStatus(buf *[]byte) ([]byte, []report, bool) {
	data := *buf
	var clean []byte
	var reports []report
	query := false
	for {
		start := bytes.Index(data, []byte{0x1b, ']'})
		if start < 0 {
			if len(data) > 0 && data[len(data)-1] == 0x1b {
				clean = append(clean, data[:len(data)-1]...)
				*buf = []byte{0x1b}
				return clean, reports, query
			}
			clean = append(clean, data...)
			*buf = nil
			return clean, reports, query
		}
		clean = append(clean, data[:start]...)
		rest := data[start+2:]
		endBEL := bytes.IndexByte(rest, 0x07)
		endST := bytes.Index(rest, []byte{0x1b, '\\'})
		end := -1
		width := 1
		if endBEL >= 0 && (endST < 0 || endBEL < endST) {
			end = endBEL
		} else if endST >= 0 {
			end = endST
			width = 2
		}
		if end < 0 {
			if len(rest) > 8192 {
				clean = append(clean, 0x1b, ']')
				clean = append(clean, rest...)
				*buf = nil
				return clean, reports, query
			}
			*buf = append([]byte{0x1b, ']'}, rest...)
			return clean, reports, query
		}
		body := string(rest[:end])
		data = rest[end+width:]
		if strings.HasPrefix(body, "7501;") || body == "7501;?" {
			payload := strings.TrimPrefix(body, "7501;")
			if payload == "?" || strings.HasPrefix(payload, "?:") {
				query = true
			} else {
				reports = append(reports, parseStatus(payload))
			}
			continue
		}
		payload := append([]byte{0x1b, ']'}, rest[:end+width]...)
		clean = append(clean, payload...)
	}
}

func parseStatus(body string) report {
	var out report
	for _, part := range strings.Split(body, ":") {
		key, val, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		switch key {
		case "state":
			out.state = val
		case "app":
			out.app = val
		case "msg":
			if raw, err := base64.StdEncoding.DecodeString(val); err == nil {
				out.msg = string(raw)
			}
		}
	}
	if body == "?" || strings.HasPrefix(body, "?:") {
		out.state = ""
	}
	return out
}

func readFrame(conn net.Conn) (map[string]any, error) {
	var n uint32
	if err := binary.Read(conn, binary.BigEndian, &n); err != nil {
		return nil, err
	}
	if n == 0 || n > 2<<20 {
		return nil, io.ErrUnexpectedEOF
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(conn, buf); err != nil {
		return nil, err
	}
	var msg map[string]any
	if err := json.Unmarshal(buf, &msg); err != nil {
		return nil, err
	}
	return msg, nil
}

func writeFrame(conn net.Conn, msg map[string]any) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	var head [4]byte
	binary.BigEndian.PutUint32(head[:], uint32(len(body)))
	if _, err := conn.Write(head[:]); err != nil {
		return err
	}
	_, err = conn.Write(body)
	return err
}

func str(msg map[string]any, key string) string {
	v, _ := msg[key].(string)
	return v
}

func intNum(msg map[string]any, key string) int {
	switch v := msg[key].(type) {
	case float64:
		return int(v)
	default:
		return 0
	}
}

func newID() string {
	buf := make([]byte, 8)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

func (h *hub) serveAPI() {
	mux := http.NewServeMux()
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		if !h.authorized(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodGet {
			_ = json.NewEncoder(w).Encode(h.list())
			return
		}
		if r.Method == http.MethodPost {
			var body struct {
				Cwd     string `json:"cwd"`
				Command string `json:"command"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			s := h.create(body.Cwd, 80, 24, body.Command)
			if s == nil {
				http.Error(w, "could not start", http.StatusInternalServerError)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"id": s.id})
			return
		}
		http.Error(w, "method", http.StatusMethodNotAllowed)
	})
	mux.HandleFunc("/sessions/", func(w http.ResponseWriter, r *http.Request) {
		if !h.authorized(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/sessions/")
		id := path
		if strings.HasSuffix(path, "/output") {
			id = strings.TrimSuffix(path, "/output")
		} else if strings.HasSuffix(path, "/input") {
			id = strings.TrimSuffix(path, "/input")
		}
		s := h.get(id)
		if s == nil {
			http.Error(w, "missing", http.StatusNotFound)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/output") {
			s.mu.Lock()
			defer s.mu.Unlock()
			_, _ = w.Write(s.scroll)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/input") && r.Method == http.MethodPost {
			raw, _ := io.ReadAll(r.Body)
			s.write(raw)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Error(w, "method", http.StatusMethodNotAllowed)
	})
	log.Printf("agent api on %s", apiPort)
	_ = http.ListenAndServe(apiPort, mux)
}

func (h *hub) authorized(r *http.Request) bool {
	return r.Header.Get("Authorization") == "Bearer "+h.token
}
