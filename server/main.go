package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

const (
	defaultListen       = "127.0.0.1:7392"
	defaultLegacyListen = "127.0.0.1:7391"
)

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

type session struct {
	id     string
	owner  string
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
	subs   map[*subscriber]struct{}
	ended  bool
}

type subscription struct {
	s   *session
	sub *subscriber
}

type hub struct {
	mu        sync.Mutex
	people    map[string]*person
	devices   map[string]bool
	sessions  map[string]*session
	macLinks  map[string][]frameWriter
	waiters   map[string]chan map[string]any
	enrolls   []enrollHit
	pairs     map[string]pairTicket
	claimMiss map[string][]time.Time
}

func main() {
	h := &hub{
		sessions: map[string]*session{},
		macLinks: map[string][]frameWriter{},
		waiters:  map[string]chan map[string]any{},
	}
	if err := h.loadPeople(); err != nil {
		log.Fatal(err)
	}
	if legacy := envOr("AETHER_LEGACY_LISTEN", defaultLegacyListen); legacy != "off" {
		go h.serveLegacy(legacy)
	}
	h.serveAPI(envOr("AETHER_LISTEN", defaultListen))
}

// serveLegacy speaks the old length-prefixed protocol on raw TCP. It stays on
// loopback unless AETHER_LEGACY_LISTEN says otherwise, since it has no TLS.
func (h *hub) serveLegacy(addr string) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("aether-sessiond listening on %s", addr)
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go h.handle(conn)
	}
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
	owner := str(hello, "token")
	if hello["type"] != "hello" || !h.known(owner) {
		_ = link.write(map[string]any{"type": "error", "message": "unauthorized"})
		return
	}
	h.addMac(owner, link)
	defer h.removeMac(owner, link)
	_ = conn.SetDeadline(time.Time{})
	_ = link.write(map[string]any{"type": "helloOk", "version": 1})
	var subs []subscription
	defer func() {
		for _, item := range subs {
			item.s.unsubscribe(item.sub)
		}
	}()
	for {
		msg, err := readFrame(conn)
		if err != nil {
			return
		}
		h.dispatch(owner, link, msg, &subs)
	}
}

func (h *hub) addMac(owner string, w frameWriter) {
	h.mu.Lock()
	h.macLinks[owner] = append(h.macLinks[owner], w)
	h.mu.Unlock()
}

func (h *hub) removeMac(owner string, w frameWriter) {
	h.mu.Lock()
	defer h.mu.Unlock()
	kept := h.macLinks[owner][:0]
	for _, item := range h.macLinks[owner] {
		if item != w {
			kept = append(kept, item)
		}
	}
	if len(kept) == 0 {
		delete(h.macLinks, owner)
		return
	}
	h.macLinks[owner] = kept
}

func (h *hub) dispatch(owner string, link frameWriter, msg map[string]any, subs *[]subscription) {
	switch msg["type"] {
	case "create":
		s, err := h.create(owner, str(msg, "cwd"), intNum(msg, "cols"), intNum(msg, "rows"), str(msg, "command"))
		if err != nil {
			_ = link.write(map[string]any{"type": "error", "message": err.Error()})
			return
		}
		sub := s.subscribe()
		*subs = append(*subs, subscription{s, sub})
		go pump(link, s.id, sub)
		_ = link.write(map[string]any{"type": "created", "id": s.id, "title": s.title})
		s.sendScroll(link)
	case "attach":
		s := h.get(str(msg, "id"))
		if s == nil || !h.allows(owner, s) {
			_ = link.write(map[string]any{"type": "error", "message": "no such session"})
			return
		}
		s.resize(intNum(msg, "cols"), intNum(msg, "rows"))
		if !subscribed(*subs, s.id) {
			sub := s.subscribe()
			*subs = append(*subs, subscription{s, sub})
			go pump(link, s.id, sub)
		}
		s.mu.Lock()
		title, state, note := s.title, s.state, s.msg
		s.mu.Unlock()
		_ = link.write(map[string]any{"type": "attached", "id": s.id, "title": title, "state": state, "msg": note})
		s.sendScroll(link)
	case "input":
		if s := h.get(str(msg, "id")); s != nil && h.allows(owner, s) {
			raw, err := base64.StdEncoding.DecodeString(str(msg, "data"))
			if err == nil && len(raw) > 0 && len(raw) <= 256*1024 {
				s.write(raw)
			}
		}
	case "resize":
		if s := h.get(str(msg, "id")); s != nil && h.allows(owner, s) {
			s.resize(intNum(msg, "cols"), intNum(msg, "rows"))
		}
	case "list":
		_ = link.write(map[string]any{"type": "sessions", "items": h.listFor(owner)})
	case "agentResult":
		h.finish(str(msg, "id"), msg)
	case "close":
		if s := h.get(str(msg, "id")); s != nil && h.allows(owner, s) {
			h.close(s.id)
		}
	case "detach":
	default:
		_ = link.write(map[string]any{"type": "error", "message": "unknown message"})
	}
}

func subscribed(subs []subscription, id string) bool {
	for _, item := range subs {
		if item.s.id == id {
			return true
		}
	}
	return false
}

func pump(conn frameWriter, id string, sub *subscriber) {
	for {
		var chunk []byte
		select {
		case chunk = <-sub.ch:
		case <-sub.done:
			return
		}
		if len(chunk) == 0 {
			continue
		}
		var err error
		switch chunk[0] {
		case 1:
			let := string(chunk[1:])
			state, msg, _ := strings.Cut(let, "\n")
			err = conn.write(map[string]any{"type": "status", "id": id, "state": state, "msg": msg})
		case 2:
			err = conn.write(map[string]any{"type": "resync", "id": id})
		case 3:
			_ = conn.write(map[string]any{"type": "closed", "id": id})
			return
		default:
			err = conn.write(map[string]any{
				"type": "output",
				"id":   id,
				"data": base64.StdEncoding.EncodeToString(chunk[1:]),
			})
		}
		if err != nil {
			return
		}
	}
}

func (h *hub) allows(owner string, s *session) bool {
	return s != nil && s.owner == owner
}

func (h *hub) create(owner, cwd string, cols, rows int, command string) (*session, error) {
	p := h.person(owner)
	if p == nil {
		return nil, errors.New("unauthorized")
	}
	own, all := h.sessionCounts(owner)
	if own >= maxSessionsPerPerson {
		return nil, errors.New("You already have 8 terminals.")
	}
	if all >= maxSessionsGlobal {
		return nil, errors.New("Cloud is full right now. Try again in a little while.")
	}
	dir, err := p.jail(cwd)
	if err != nil {
		return nil, err
	}
	if len(command) > 4000 {
		return nil, errors.New("that command is too long")
	}
	if cols < 20 {
		cols = 80
	}
	if rows < 5 {
		rows = 24
	}
	if cols > 500 {
		cols = 500
	}
	if rows > 200 {
		rows = 200
	}
	cmd := exec.Command("/bin/bash", "-l")
	if strings.TrimSpace(command) != "" {
		cmd = exec.Command("/bin/bash", "-lc", command)
	}
	cmd.Dir = dir
	id := newID()
	cmd.Env = []string{
		"HOME=" + p.Home,
		"USER=" + p.User,
		"LOGNAME=" + p.User,
		"SHELL=/bin/bash",
		"TERM=xterm-256color",
		"TERM_PROGRAM=Aether",
		"AETHER_SESSION=" + id,
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"LANG=C.UTF-8",
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential: &syscall.Credential{Uid: p.UID, Gid: p.GID},
	}
	master, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, errors.New("could not start a session")
	}
	if cmd.Process != nil {
		_ = exec.Command("prlimit", "--pid", strconv.Itoa(cmd.Process.Pid), "--nproc=128", "--nofile=4096").Run()
	}
	s := &session{
		id: id, owner: owner, cmd: cmd, master: master, cols: cols, rows: rows, cwd: dir,
		title: "shell", state: "idle", subs: map[*subscriber]struct{}{},
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
		s.end()
		h.mu.Lock()
		delete(h.sessions, id)
		h.mu.Unlock()
	}()
	return s, nil
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
				s.output(clean)
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

// output records p in the scrollback and fans it out under one lock, so a
// viewer that attaches in between never sees a chunk twice or not at all.
func (s *session) output(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.scroll = append(s.scroll, p...)
	if len(s.scroll) > 1<<20 {
		s.scroll = append([]byte(nil), s.scroll[len(s.scroll)-1<<20:]...)
	}
	s.broadcastLocked(append([]byte{0}, p...))
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

// subscriber carries one viewer's copy of a session's output. Its data
// channel is never closed, so senders can't panic; viewers that leave close
// done instead, and senders only touch ch while holding s.mu.
type subscriber struct {
	ch   chan []byte
	done chan struct{}
	once sync.Once
}

func (sub *subscriber) stop() {
	sub.once.Do(func() { close(sub.done) })
}

func (s *session) subscribe() *subscriber {
	sub := &subscriber{ch: make(chan []byte, 128), done: make(chan struct{})}
	s.mu.Lock()
	if s.ended {
		s.mu.Unlock()
		sub.ch <- []byte{3}
		return sub
	}
	s.subs[sub] = struct{}{}
	s.mu.Unlock()
	return sub
}

func (s *session) unsubscribe(sub *subscriber) {
	s.mu.Lock()
	delete(s.subs, sub)
	s.mu.Unlock()
	sub.stop()
}

// deliverLocked hands msg to sub without blocking. A viewer that has fallen
// behind loses its queued output and is told to resync from the scrollback.
// Callers hold s.mu, which makes this the only sender, so the drain always
// leaves room.
func (s *session) deliverLocked(sub *subscriber, msg []byte) {
	select {
	case sub.ch <- msg:
		return
	default:
	}
drain:
	for {
		select {
		case <-sub.ch:
		default:
			break drain
		}
	}
	sub.ch <- []byte{2}
	if msg[0] != 0 {
		sub.ch <- msg
	}
}

func (s *session) broadcastLocked(msg []byte) {
	for sub := range s.subs {
		s.deliverLocked(sub, msg)
	}
}

func (s *session) broadcastStatus(state, msg string) {
	body := append([]byte{1}, []byte(state+"\n"+msg)...)
	s.mu.Lock()
	s.broadcastLocked(body)
	s.mu.Unlock()
}

// end tells every viewer the session is gone and forgets them.
func (s *session) end() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ended {
		return
	}
	s.ended = true
	for sub := range s.subs {
		s.deliverLocked(sub, []byte{3})
		delete(s.subs, sub)
	}
}

func (s *session) sendScroll(conn frameWriter) {
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

func (h *hub) listFor(owner string) []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	items := make([]map[string]any, 0, len(h.sessions))
	for _, s := range h.sessions {
		if s.owner != owner {
			continue
		}
		s.mu.Lock()
		items = append(items, map[string]any{
			"id": s.id, "title": s.title, "cwd": s.cwd, "state": s.state, "msg": s.msg,
			"cols": s.cols, "rows": s.rows,
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

func writePublic(w http.ResponseWriter, token string) {
	web, ws, host := publicEndpoint()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Referrer-Policy", "no-referrer")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"token": token,
		"host":  host,
		"ws":    ws,
		"web":   web,
	})
}

func (h *hub) serveAPI(addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/enroll", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		ip := clientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"), r.Header.Get("CF-Connecting-IP"))
		p, err := h.enrollSaved(ip)
		if err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		log.Printf("enrolled %s", p.User)
		writePublic(w, p.Token)
	})
	mux.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		code, exp, err := h.issuePair(token)
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		web, _, _ := publicEndpoint()
		url := ""
		if web != "" {
			url = web + "/?pair=" + code
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Referrer-Policy", "no-referrer")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code": code, "url": url, "expires": int(time.Until(exp).Seconds()),
		})
	})
	mux.HandleFunc("/claim", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Code string `json:"code"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		ip := clientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"), r.Header.Get("CF-Connecting-IP"))
		token, err := h.claimPair(body.Code, ip)
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}
		writePublic(w, token)
	})
	mux.HandleFunc("/ws", h.serveWS)
	mux.HandleFunc("/agent", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		owner := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !h.known(owner) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		var body struct {
			Path    string         `json:"path"`
			Session string         `json:"session"`
			Body    map[string]any `json:"body"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		s := h.get(body.Session)
		if s == nil || !h.allows(owner, s) {
			http.Error(w, "missing", http.StatusNotFound)
			return
		}
		res, err := h.ask(s.owner, body.Path, body.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(res)
	})
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		if !h.authorized(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodGet {
			owner := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			_ = json.NewEncoder(w).Encode(h.listFor(owner))
			return
		}
		if r.Method == http.MethodPost {
			var body struct {
				Cwd     string `json:"cwd"`
				Command string `json:"command"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			owner := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			s, err := h.create(owner, body.Cwd, 80, 24, body.Command)
			if err != nil {
				http.Error(w, err.Error(), http.StatusServiceUnavailable)
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
		owner := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if s == nil || !h.allows(owner, s) {
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
			r.Body = http.MaxBytesReader(w, r.Body, 256*1024)
			raw, err := io.ReadAll(r.Body)
			if err != nil || len(raw) == 0 {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			s.write(raw)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Error(w, "method", http.StatusMethodNotAllowed)
	})
	mux.Handle("/", webHandler())
	log.Printf("agent api on %s", addr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func (h *hub) authorized(r *http.Request) bool {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	return h.known(token)
}

func (h *hub) ask(owner, path string, body map[string]any) (map[string]any, error) {
	id := newID()
	ch := make(chan map[string]any, 1)
	h.mu.Lock()
	var link frameWriter
	if links := h.macLinks[owner]; len(links) > 0 {
		link = links[len(links)-1]
	}
	h.waiters[id] = ch
	h.mu.Unlock()
	if link == nil {
		h.mu.Lock()
		delete(h.waiters, id)
		h.mu.Unlock()
		return nil, errors.New("the Mac that owns this session is not connected")
	}
	if err := link.write(map[string]any{"type": "agent", "id": id, "path": path, "body": body}); err != nil {
		return nil, err
	}
	select {
	case res := <-ch:
		return res, nil
	case <-time.After(8 * time.Second):
		h.mu.Lock()
		delete(h.waiters, id)
		h.mu.Unlock()
		return nil, errors.New("the Mac did not answer")
	}
}

func (h *hub) finish(id string, msg map[string]any) {
	h.mu.Lock()
	ch := h.waiters[id]
	delete(h.waiters, id)
	h.mu.Unlock()
	if ch != nil {
		ch <- msg
	}
}
