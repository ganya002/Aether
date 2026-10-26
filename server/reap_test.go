package main

import (
	"os/exec"
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
