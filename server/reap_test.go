package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestIdlePeopleExpire(t *testing.T) {
	now := time.Now()
	old := now.Add(-40 * 24 * time.Hour).Unix()
	h := &hub{
		people: map[string]*person{
			"idle":    {Token: "idle", User: "aeidle", LastSeen: old},
			"recent":  {Token: "recent", User: "aerecent", LastSeen: now.Unix()},
			"working": {Token: "working", User: "aework", LastSeen: old},
			"mac":     {Token: "mac", User: "aemac", LastSeen: old},
			"device":  {Token: "device", User: "aedevice", LastSeen: old},
			"legacy":  {Token: "legacy", User: "aelegacy", Created: old},
		},
		sessions: map[string]*session{"s": {id: "s", owner: "working"}},
		macLinks: map[string][]frameWriter{"mac": {&nullWriter{}}},
		devices:  map[string]bool{"device": true},
		pairs:    map[string]pairTicket{"ABCD-EFGH": {token: "idle", exp: now.Add(time.Minute)}},
	}
	gone := h.expireIdle(now, 30*24*time.Hour)
	names := map[string]bool{}
	for _, p := range gone {
		names[p.User] = true
	}
	if len(gone) != 2 || !names["aeidle"] || !names["aelegacy"] {
		t.Fatalf("expired %v", names)
	}
	for _, keep := range []string{"recent", "working", "mac", "device"} {
		if h.people[keep] == nil {
			t.Fatalf("%s was removed", keep)
		}
	}
	if len(h.pairs) != 0 {
		t.Fatal("a pair code still points at an expired person")
	}
	if got := h.expireIdle(now, 0); got != nil {
		t.Fatal("expiry ran while disabled")
	}
}

func TestKillGroupTakesBackgroundJobs(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "nohup sleep 30 >/dev/null 2>&1 & echo $!; wait")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 32)
	n, _ := out.Read(buf)
	var child int
	for _, c := range buf[:n] {
		if c >= '0' && c <= '9' {
			child = child*10 + int(c-'0')
		}
	}
	if child == 0 {
		t.Fatal("no background pid")
	}
	killGroup(cmd.Process.Pid)
	_ = cmd.Wait()
	deadline := time.Now().Add(2 * time.Second)
	for syscall.Kill(child, 0) == nil {
		if time.Now().After(deadline) {
			_ = syscall.Kill(child, syscall.SIGKILL)
			t.Fatal("background job outlived its shell")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// people.json usually holds LastSeen from when a person enrolled. A restart
// must not read that as "gone for a month" and delete people still using Cloud.
func TestRestartDoesNotExpireActivePeople(t *testing.T) {
	dir := useStateDir(t)
	old := time.Now().Add(-90 * 24 * time.Hour).Unix()
	body := `{"people":[{"token":"tok","user":"aenobody","home":"/nowhere","created":` + strconv.FormatInt(old, 10) +
		`,"lastSeen":` + strconv.FormatInt(old, 10) + `}]}`
	if err := os.WriteFile(filepath.Join(dir, "people.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	h := &hub{}
	if err := h.loadPeople(); err != nil {
		t.Fatal(err)
	}
	if gone := h.expireIdle(time.Now(), 30*24*time.Hour); len(gone) != 0 {
		t.Fatal("a restart expired someone")
	}
	if gone := h.expireIdle(time.Now().Add(31*24*time.Hour), 30*24*time.Hour); len(gone) != 1 {
		t.Fatal("the grace period never ends")
	}
}

func TestReapTickSavesLastSeen(t *testing.T) {
	dir := useStateDir(t)
	t.Setenv("AETHER_PERSON_IDLE_DAYS", "30")
	h := &hub{
		people:    map[string]*person{"tok": {Token: "tok", User: "aenobody", Home: "/nowhere", Created: 1, LastSeen: 1}},
		claimMiss: map[string][]time.Time{},
	}
	h.devices = map[string]bool{"tok": true}
	path := filepath.Join(dir, "people.json")
	h.reapTick(time.Now())
	if _, err := os.Stat(path); err == nil {
		t.Fatal("saved with nothing new")
	}
	h.person("tok")
	h.reapTick(time.Now())
	again := &hub{}
	if err := again.loadPeople(); err != nil {
		t.Fatal(err)
	}
	if seen := again.people["tok"].LastSeen; time.Since(time.Unix(seen, 0)) > time.Minute {
		t.Fatalf("LastSeen on disk is %d", seen)
	}
}

func TestSweepSparesAShellThatIsStarting(t *testing.T) {
	killed := 0
	saved := killUser
	killUser = func(uint32) { killed++ }
	t.Cleanup(func() { killUser = saved })
	h := &hub{people: map[string]*person{"tok": {Token: "tok", UID: 1234}}, sessions: map[string]*session{}}
	h.markStarting("tok", 1)
	h.sweepUser("tok")
	if killed != 0 {
		t.Fatal("swept while a shell was starting")
	}
	h.markStarting("tok", -1)
	h.sweepUser("tok")
	if killed != 1 {
		t.Fatal("did not sweep an idle person")
	}
}
