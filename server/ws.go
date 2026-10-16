package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
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
		OriginPatterns: []string{"*"},
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
			item.s.unsubscribe(item.ch)
		}
	}()
	for {
		_, data, err := conn.Read(context.Background())
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

func webHandler() http.Handler {
	sub, err := fs.Sub(webFiles, "web")
	if err != nil {
		log.Printf("web files: %v", err)
		return http.NotFoundHandler()
	}
	files := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		files.ServeHTTP(w, r)
	})
}
