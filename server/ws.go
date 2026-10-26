package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type frameWriter interface {
	write(msg map[string]any) error
}

type wsLink struct {
	c  *websocket.Conn
	mu sync.Mutex
}

func (w *wsLink) write(msg map[string]any) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	return w.c.Write(ctx, websocket.MessageText, body)
}

func (h *hub) serveWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns: originPatterns(),
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(1 << 20)
	defer conn.Close(websocket.StatusNormalClosure, "")
	link := &wsLink{c: conn}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	_, data, err := conn.Read(ctx)
	cancel()
	if err != nil {
		return
	}
	var hello map[string]any
	if json.Unmarshal(data, &hello) != nil || hello["type"] != "hello" || !h.known(str(hello, "token")) {
		_ = link.write(map[string]any{"type": "error", "message": "unauthorized"})
		return
	}
	owner := str(hello, "token")
	if str(hello, "client") != "web" {
		h.addMac(owner, link)
		defer h.removeMac(owner, link)
	}
	if err := link.write(map[string]any{"type": "helloOk", "version": 1}); err != nil {
		return
	}
	var subs []subscription
	defer func() {
		for _, item := range subs {
			item.s.unsubscribe(item.sub)
		}
	}()
	alive, stop := context.WithCancel(r.Context())
	defer stop()
	go keepAlive(alive, conn)
	for {
		_, data, err := conn.Read(alive)
		if err != nil {
			return
		}
		var msg map[string]any
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		h.dispatch(owner, link, msg, &subs)
	}
}

// keepAlive pings the peer so a socket whose other end vanished (a laptop
// lid closing, a phone dropping off Wi-Fi) is noticed and its viewers freed.
func keepAlive(ctx context.Context, conn *websocket.Conn) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		pingCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := conn.Ping(pingCtx)
		cancel()
		if err != nil {
			if ctx.Err() == nil {
				conn.CloseNow()
			}
			return
		}
	}
}

// originPatterns lists the pages allowed to open a socket from a browser:
// the published address and this machine. Same-host pages are always allowed.
// Until the address is known every origin is let through, because the token
// still has to arrive in the first message.
func originPatterns() []string {
	web, _, _ := publicEndpoint()
	u, err := url.Parse(web)
	if web == "" || err != nil || u.Host == "" {
		return []string{"*"}
	}
	return []string{u.Host, "localhost", "localhost:*", "127.0.0.1", "127.0.0.1:*"}
}

// securityHeaders wraps every response. The page loads only its own scripts
// and talks only to its own socket; xterm.js adds <style> elements at runtime,
// which is why inline styles are allowed.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connect := "'self'"
		if safeHost(r.Host) {
			connect += " wss://" + r.Host + " ws://" + r.Host
		}
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
			"img-src 'self' data:; font-src 'self'; connect-src "+connect+"; object-src 'none'; base-uri 'none'; "+
			"form-action 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

func safeHost(host string) bool {
	if host == "" || len(host) > 255 {
		return false
	}
	for _, c := range host {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == ':') {
			return false
		}
	}
	return true
}

func webHandler() http.Handler {
	sub, err := fs.Sub(webFiles, "web")
	if err != nil {
		log.Printf("web files: %v", err)
		return http.NotFoundHandler()
	}
	files := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		files.ServeHTTP(w, r)
	})
}
