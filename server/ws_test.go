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
