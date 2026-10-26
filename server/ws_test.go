package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/coder/websocket"
)

func TestSocketOriginFollowsPublicAddress(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("AETHER_PUBLIC_URL", "https://cloud.example")
	publicURLFile = dir + "/missing.url"
	publicEnvFile = dir + "/missing.env"
	t.Cleanup(func() { publicURLFile, publicEnvFile = defaultPublicURLFile, defaultPublicEnvFile })
	h := &hub{people: map[string]*person{}, sessions: map[string]*session{}, macLinks: map[string][]frameWriter{}}
	srv := httptest.NewServer(http.HandlerFunc(h.serveWS))
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	dial := func(origin string) error {
		header := http.Header{}
		if origin != "" {
			header.Set("Origin", origin)
		}
		c, _, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{HTTPHeader: header})
		if err == nil {
			c.Close(websocket.StatusNormalClosure, "")
		}
		return err
	}
	if err := dial("https://evil.example"); err == nil {
		t.Fatal("a foreign page opened a socket")
	}
	if err := dial("https://cloud.example"); err != nil {
		t.Fatalf("published page refused: %v", err)
	}
	if err := dial(""); err != nil {
		t.Fatalf("native client refused: %v", err)
	}
}

func TestPageSecurityHeaders(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "http://cloud.example/", nil)
	securityHeaders(webHandler()).ServeHTTP(rec, req)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "app.js") {
		t.Fatalf("page: %d", rec.Code)
	}
	csp := rec.Header().Get("Content-Security-Policy")
	for _, want := range []string{"default-src 'self'", "frame-ancestors 'none'", "script-src 'self';", "wss://cloud.example"} {
		if !strings.Contains(csp, want) {
			t.Fatalf("csp %q lacks %q", csp, want)
		}
	}
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" || rec.Header().Get("Referrer-Policy") != "no-referrer" {
		t.Fatal("missing nosniff or referrer policy")
	}
	bad := httptest.NewRequest("GET", "http://cloud.example/", nil)
	bad.Host = "evil.example; script-src *"
	rec = httptest.NewRecorder()
	securityHeaders(webHandler()).ServeHTTP(rec, bad)
	if strings.Contains(rec.Header().Get("Content-Security-Policy"), "evil") {
		t.Fatal("host header leaked into the policy")
	}
}

func TestPageServesAppFiles(t *testing.T) {
	for path, want := range map[string]string{
		"/manifest.webmanifest":  "application/manifest+json",
		"/apple-touch-icon.png":  "image/png",
		"/icon-192.png":          "image/png",
		"/icon-512.png":          "image/png",
		"/icon-maskable-512.png": "image/png",
		"/icon-32.png":           "image/png",
	} {
		rec := httptest.NewRecorder()
		securityHeaders(webHandler()).ServeHTTP(rec, httptest.NewRequest("GET", "http://cloud.example"+path, nil))
		if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Type"), want) {
			t.Fatalf("%s: %d %q", path, rec.Code, rec.Header().Get("Content-Type"))
		}
	}
	rec := httptest.NewRecorder()
	securityHeaders(webHandler()).ServeHTTP(rec, httptest.NewRequest("GET", "http://cloud.example/", nil))
	if !strings.Contains(rec.Header().Get("Content-Security-Policy"), "manifest-src 'self'") {
		t.Fatal("the policy blocks the manifest")
	}
}

func TestSocketAnswersPing(t *testing.T) {
	usePublicFiles(t)
	t.Setenv("AETHER_PUBLIC_URL", "")
	h := &hub{
		people:   map[string]*person{"tok": {Token: "tok"}},
		sessions: map[string]*session{},
		macLinks: map[string][]frameWriter{},
	}
	srv := httptest.NewServer(http.HandlerFunc(h.serveWS))
	defer srv.Close()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	read := func() string {
		_, data, err := c.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	_ = c.Write(ctx, websocket.MessageText, []byte(`{"type":"hello","token":"tok","client":"web"}`))
	if got := read(); !strings.Contains(got, "helloOk") {
		t.Fatalf("hello: %s", got)
	}
	_ = c.Write(ctx, websocket.MessageText, []byte(`{"type":"ping"}`))
	if got := read(); got != `{"type":"pong"}` {
		t.Fatalf("ping: %s", got)
	}
}
