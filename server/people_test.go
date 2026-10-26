package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestJailKeepsPeopleApart(t *testing.T) {
	p := &person{Home: "/var/lib/aether/homes/aeabcdef12"}
	home, err := p.jail("")
	if err != nil || home != p.Home {
		t.Fatalf("empty cwd: %q %v", home, err)
	}
	got, err := p.jail("projects/app")
	if err != nil || got != p.Home+"/projects/app" {
		t.Fatalf("relative: %q %v", got, err)
	}
	if _, err := p.jail("/etc"); err == nil {
		t.Fatal("escaped to /etc")
	}
	if _, err := p.jail("/var/lib/aether/homes/aeother/secret"); err == nil {
		t.Fatal("read another home")
	}
	if _, err := p.jail("../../etc/passwd"); err == nil {
		t.Fatal("dotdot escape")
	}
	if _, err := p.jail(p.Home + "/../aeother"); err == nil {
		t.Fatal("cleaned escape")
	}
}

func TestEnrollRateAndCaps(t *testing.T) {
	h := &hub{people: map[string]*person{}, sessions: map[string]*session{}}
	now := time.Now()
	for i := 0; i < enrollPerIPHour; i++ {
		if !h.allowEnroll("10.0.0.8", now) {
			t.Fatalf("enroll %d should be allowed", i)
		}
	}
	if h.allowEnroll("10.0.0.8", now) {
		t.Fatal("same address kept enrolling")
	}
	if !h.allowEnroll("10.0.0.9", now) {
		t.Fatal("a different address was blocked by the per-address cap")
	}
	s := &session{id: "s", owner: "alice"}
	h.sessions[s.id] = s
	other := &session{id: "o", owner: "bob"}
	h.sessions[other.id] = other
	if h.allows("bob", s) {
		t.Fatal("bob can see alice")
	}
	if !h.allows("alice", s) {
		t.Fatal("alice cannot see her own session")
	}
	if h.allows("shared-admin-token", s) {
		t.Fatal("a shared token still opens every session")
	}
	own, all := h.sessionCounts("alice")
	if own != 1 || all != 2 {
		t.Fatalf("counts own=%d all=%d", own, all)
	}
}

func TestPairCodeIsSingleUse(t *testing.T) {
	h := &hub{
		people:    map[string]*person{"tok": {Token: "tok"}},
		pairs:     map[string]pairTicket{},
		claimMiss: map[string][]time.Time{},
	}
	code, _, err := h.issuePair("tok")
	if err != nil || len(code) != 9 || code[4] != '-' {
		t.Fatalf("code %q err %v", code, err)
	}
	got, err := h.claimPair(code, "1.2.3.4")
	if err != nil || got != "tok" {
		t.Fatalf("claim %q %v", got, err)
	}
	if _, err := h.claimPair(code, "1.2.3.4"); err == nil {
		t.Fatal("code worked twice")
	}
	if _, _, err := h.issuePair("nope"); err == nil {
		t.Fatal("unknown token got a code")
	}
}

func usePublicFiles(t *testing.T) (urlFile, envFile string) {
	dir := t.TempDir()
	publicURLFile = filepath.Join(dir, "public.url")
	publicEnvFile = filepath.Join(dir, "public.env")
	t.Cleanup(func() { publicURLFile, publicEnvFile = defaultPublicURLFile, defaultPublicEnvFile })
	return publicURLFile, publicEnvFile
}

func TestPublicEndpoint(t *testing.T) {
	urlFile, envFile := usePublicFiles(t)
	t.Setenv("AETHER_PUBLIC_URL", "https://cloud.example/")
	web, ws, host := publicEndpoint()
	if web != "https://cloud.example" || ws != "wss://cloud.example/ws" || host != "cloud.example" {
		t.Fatalf("got %s %s %s", web, ws, host)
	}
	if err := os.WriteFile(envFile, []byte("AETHER_PUBLIC_URL=https://env-file.example\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if web, _, _ := publicEndpoint(); web != "https://env-file.example" {
		t.Fatalf("env file ignored: %s", web)
	}
	if err := os.WriteFile(urlFile, []byte("https://fresh.trycloudflare.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if web, _, _ := publicEndpoint(); web != "https://fresh.trycloudflare.com" {
		t.Fatalf("stale address: %s", web)
	}
	if err := os.WriteFile(urlFile, []byte("https://newer.trycloudflare.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if web, _, _ := publicEndpoint(); web != "https://newer.trycloudflare.com" {
		t.Fatalf("address was cached: %s", web)
	}
}

func TestClientIP(t *testing.T) {
	if got := clientIP("127.0.0.1:9", "198.51.100.4, 10.0.0.1", ""); got != "10.0.0.1" {
		t.Fatal(got)
	}
	if got := clientIP("127.0.0.1:9", "10.0.0.1", "203.0.113.9"); got != "203.0.113.9" {
		t.Fatal(got)
	}
	if got := clientIP("[::1]:9", "", "203.0.113.9"); got != "203.0.113.9" {
		t.Fatal(got)
	}
	if got := clientIP("198.51.100.7:5000", "1.1.1.1", "2.2.2.2"); got != "198.51.100.7" {
		t.Fatalf("trusted headers from a remote caller: %s", got)
	}
	if got := clientIP("[2001:db8::1]:443", "", "2.2.2.2"); got != "2001:db8::1" {
		t.Fatal(got)
	}
}

func useStateDir(t *testing.T) string {
	dir := t.TempDir()
	old := stateDir
	stateDir = dir
	t.Cleanup(func() { stateDir = old })
	return dir
}

func TestLoadPeopleRefusesDamagedFile(t *testing.T) {
	dir := useStateDir(t)
	h := &hub{}
	if err := h.loadPeople(); err != nil {
		t.Fatalf("missing file should start empty: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "people.json"), []byte(`{"people": [`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := h.loadPeople(); err == nil {
		t.Fatal("started with a damaged people.json")
	}
	good := `{"people":[{"token":"tok","user":"aenobody","home":"/nowhere","created":1}]}`
	if err := os.WriteFile(filepath.Join(dir, "people.json"), []byte(good), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := h.loadPeople(); err != nil || h.person("tok") == nil {
		t.Fatalf("good file: %v", err)
	}
	if h.person("tok").LastSeen == 0 {
		t.Fatal("old entries should get a fresh grace period")
	}
	h.savePeople()
	again := &hub{}
	if err := again.loadPeople(); err != nil || again.person("tok") == nil {
		t.Fatalf("round trip: %v", err)
	}
}
