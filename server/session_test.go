package main

import (
	"errors"
	"sync"
	"testing"
	"time"
)

type nullWriter struct {
	mu   sync.Mutex
	msgs []map[string]any
	slow time.Duration
	fail bool
}

func (w *nullWriter) write(msg map[string]any) error {
	if w.slow > 0 {
		time.Sleep(w.slow)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.fail {
		return errors.New("gone")
	}
	w.msgs = append(w.msgs, msg)
	return nil
}

func (w *nullWriter) types() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]string, 0, len(w.msgs))
	for _, m := range w.msgs {
		out = append(out, m["type"].(string))
	}
	return out
}

func newTestSession() *session {
	return &session{id: "s", subs: map[*subscriber]struct{}{}}
}

// Viewers coming and going while output, status, and exit race each other
// used to panic with "send on closed channel" and take the server down.
func TestBroadcastSurvivesViewersLeaving(t *testing.T) {
	for round := 0; round < 50; round++ {
		s := newTestSession()
		var wg sync.WaitGroup
		stop := make(chan struct{})
		for i := 0; i < 4; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				chunk := []byte("hello world\r\n")
				for {
					select {
					case <-stop:
						return
					default:
					}
					s.output(chunk)
					s.broadcastStatus("working", "busy")
				}
			}()
		}
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				for j := 0; j < 20; j++ {
					sub := s.subscribe()
					w := &nullWriter{}
					if i%2 == 0 {
						w.slow = time.Millisecond
					}
					done := make(chan struct{})
					go func() {
						pump(w, s.id, sub)
						close(done)
					}()
					s.unsubscribe(sub)
					s.unsubscribe(sub)
					<-done
				}
			}(i)
		}
		time.Sleep(2 * time.Millisecond)
		s.end()
		close(stop)
		wg.Wait()
		s.end()
	}
}

func TestSlowViewerIsToldToResync(t *testing.T) {
	s := newTestSession()
	sub := s.subscribe()
	for i := 0; i < 1000; i++ {
		s.output([]byte("x"))
	}
	s.broadcastStatus("done", "ok")
	var kinds []byte
	for len(sub.ch) > 0 {
		kinds = append(kinds, (<-sub.ch)[0])
	}
	resync := false
	for _, k := range kinds {
		if k == 2 {
			resync = true
		}
	}
	if !resync {
		t.Fatalf("no resync after overflow: %v", kinds)
	}
	if kinds[len(kinds)-1] != 1 {
		t.Fatalf("status was lost: %v", kinds)
	}
}

func TestEndedSessionClosesViewers(t *testing.T) {
	s := newTestSession()
	sub := s.subscribe()
	w := &nullWriter{}
	done := make(chan struct{})
	go func() {
		pump(w, s.id, sub)
		close(done)
	}()
	s.output([]byte("bye"))
	s.end()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not stop after the session ended")
	}
	got := w.types()
	if len(got) != 2 || got[0] != "output" || got[1] != "closed" {
		t.Fatalf("got %v", got)
	}
	late := s.subscribe()
	if c := <-late.ch; c[0] != 3 {
		t.Fatalf("late viewer got %v", c)
	}
	s.unsubscribe(late)
}

func TestAskForgetsWaiterWhenTheMacIsGone(t *testing.T) {
	h := &hub{
		macLinks: map[string][]frameWriter{"tok": {&nullWriter{fail: true}}},
		waiters:  map[string]chan map[string]any{},
	}
	if _, err := h.ask("tok", "/split", nil, time.Second); err == nil {
		t.Fatal("ask succeeded over a dead link")
	}
	if len(h.waiters) != 0 {
		t.Fatalf("leaked %d waiters", len(h.waiters))
	}
}

// answeringWriter plays a Mac that answers every agent request right away.
type answeringWriter struct {
	h    *hub
	mu   sync.Mutex
	sent []map[string]any
}

func (w *answeringWriter) write(msg map[string]any) error {
	w.mu.Lock()
	w.sent = append(w.sent, msg)
	w.mu.Unlock()
	go w.h.finish(str(msg, "id"), map[string]any{"ok": true})
	return nil
}

func TestAgentCallsActForTheirOwnSessionOnly(t *testing.T) {
	h := &hub{waiters: map[string]chan map[string]any{}}
	mac := &answeringWriter{h: h}
	h.macLinks = map[string][]frameWriter{"alice": {mac}}
	mine := &session{id: "mine", owner: "alice"}
	before := time.Now()
	if _, err := h.forwardAgent(mine, "/read", map[string]any{"session": "someone-else", "pane": "local"}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.forwardAgent(mine, "/split", map[string]any{"command": "make"}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.forwardAgent(mine, "/zoom", nil); err != nil {
		t.Fatal(err)
	}
	mac.mu.Lock()
	defer mac.mu.Unlock()
	if len(mac.sent) != 3 {
		t.Fatalf("sent %d requests", len(mac.sent))
	}
	for _, msg := range mac.sent {
		body, _ := msg["body"].(map[string]any)
		if body["session"] != "mine" {
			t.Fatalf("forwarded session %v", body["session"])
		}
	}
	deadline := func(i int) time.Duration {
		ms, _ := mac.sent[i]["deadline"].(int64)
		return time.UnixMilli(ms).Sub(before)
	}
	if d := deadline(0); d < agentQuickWait-time.Second || d > agentQuickWait+5*time.Second {
		t.Fatalf("a read waits %v", d)
	}
	if d := deadline(1); d < agentApprovalWait-time.Second || d > agentApprovalWait+5*time.Second {
		t.Fatalf("a command waits %v", d)
	}
}

func TestSessionTokenOnlyOpensItsOwnSession(t *testing.T) {
	mine := &session{id: "a", owner: "alice", token: newSecret()}
	other := &session{id: "b", owner: "alice", token: newSecret()}
	bobs := &session{id: "c", owner: "bob", token: newSecret()}
	h := &hub{
		people:   map[string]*person{"alice": {Token: "alice"}, "bob": {Token: "bob"}},
		sessions: map[string]*session{"a": mine, "b": other, "c": bobs},
	}
	if h.agentSession(mine.token, "a") != mine {
		t.Fatal("session token refused for its own session")
	}
	if h.agentSession(mine.token, "b") != nil {
		t.Fatal("session token opened a sibling session")
	}
	if h.agentSession(mine.token, "c") != nil {
		t.Fatal("session token opened someone else's session")
	}
	if h.known(mine.token) {
		t.Fatal("session token works as a person token")
	}
	if h.agentSession("alice", "b") != other || h.agentSession("alice", "c") != nil {
		t.Fatal("person token rules changed")
	}
	if h.agentSession("", "a") != nil {
		t.Fatal("empty token accepted")
	}
}

func TestRepliesEchoTheRequestTag(t *testing.T) {
	h := &hub{sessions: map[string]*session{}}
	w := &nullWriter{}
	var subs []subscription
	h.dispatch("tok", w, map[string]any{"type": "attach", "id": "nope", "req": "r7"}, &subs)
	h.dispatch("tok", w, map[string]any{"type": "attach", "id": "nope"}, &subs)
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.msgs) != 2 || w.msgs[0]["req"] != "r7" {
		t.Fatalf("got %v", w.msgs)
	}
	if _, ok := w.msgs[1]["req"]; ok {
		t.Fatalf("untagged request got a tag: %v", w.msgs[1])
	}
}
