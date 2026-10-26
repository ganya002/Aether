package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const defaultIdleDays = 30

// idleLimit is how long a person can go without connecting, while holding no
// terminals, before their account is removed and the slot freed. Set
// AETHER_PERSON_IDLE_DAYS=0 to keep everyone forever.
func idleLimit() time.Duration {
	days := defaultIdleDays
	if raw := strings.TrimSpace(os.Getenv("AETHER_PERSON_IDLE_DAYS")); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n >= 0 {
			days = n
		}
	}
	return time.Duration(days) * 24 * time.Hour
}

// killGroup ends a shell together with everything it started in its process
// group, including nohup'd jobs that would otherwise outlive the terminal.
func killGroup(pid int) {
	if pid <= 1 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}

// killUser ends every process owned by uid. It is used once a person has no
// terminals left, to catch jobs that escaped their process group with setsid.
var killUser = func(uid uint32) {
	if uid == 0 {
		return
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 1 {
			continue
		}
		b, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "status"))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			if !strings.HasPrefix(line, "Uid:") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[1] == strconv.FormatUint(uint64(uid), 10) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
			break
		}
	}
}

// removeUser deletes the Unix account and home of an expired person.
var removeUser = func(p *person) {
	if !strings.HasPrefix(p.User, "ae") || filepath.Dir(filepath.Clean(p.Home)) != filepath.Join(stateDir, "homes") {
		return
	}
	if out, err := exec.Command("userdel", "--remove", p.User).CombinedOutput(); err != nil {
		log.Printf("removing %s: %v %s", p.User, err, strings.TrimSpace(string(out)))
	}
}

func (h *hub) markStarting(owner string, delta int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.starting == nil {
		h.starting = map[string]int{}
	}
	h.starting[owner] += delta
	if h.starting[owner] <= 0 {
		delete(h.starting, owner)
	}
}

// sweepUser cleans up after owner once their last terminal is gone. It holds
// the lock while it kills, so a terminal opening at the same moment either
// counts as busy or starts after the sweep.
func (h *hub) sweepUser(owner string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.people[owner]
	if p == nil || h.starting[owner] > 0 {
		return
	}
	for _, s := range h.sessions {
		if s.owner == owner {
			return
		}
	}
	killUser(p.UID)
}

// expireIdle removes people who have no terminals, no connected Mac, and have
// not been seen within limit. Tokens listed in the devices file are kept.
func (h *hub) expireIdle(now time.Time, limit time.Duration) []*person {
	if limit <= 0 {
		return nil
	}
	cutoff := now.Add(-limit).Unix()
	h.mu.Lock()
	busy := map[string]bool{}
	for _, s := range h.sessions {
		busy[s.owner] = true
	}
	for owner := range h.macLinks {
		busy[owner] = true
	}
	var gone []*person
	for token, p := range h.people {
		seen := p.LastSeen
		if seen == 0 {
			seen = p.Created
		}
		if p.loaded > seen {
			seen = p.loaded
		}
		if busy[token] || h.devices[token] || seen > cutoff {
			continue
		}
		delete(h.people, token)
		gone = append(gone, p)
	}
	for code, ticket := range h.pairs {
		if h.people[ticket.token] == nil {
			delete(h.pairs, code)
		}
	}
	h.mu.Unlock()
	return gone
}

const reapInterval = time.Hour

// reapLoop waits a full interval before its first sweep, so a restart never
// judges anyone before they have had a chance to reconnect.
func (h *hub) reapLoop() {
	for {
		time.Sleep(reapInterval)
		h.reapTick(time.Now())
	}
}

// reapTick removes idle people and writes people.json when that, or anyone's
// LastSeen, changed. Without the write a restart would forget who was active.
func (h *hub) reapTick(now time.Time) {
	gone := h.expireIdle(now, idleLimit())
	h.mu.Lock()
	changed := h.seenChanged
	h.seenChanged = false
	h.mu.Unlock()
	if len(gone) > 0 || changed {
		saveMu.Lock()
		h.savePeople()
		saveMu.Unlock()
	}
	for _, p := range gone {
		log.Printf("expired %s after %s idle", p.User, idleLimit())
		killUser(p.UID)
		removeUser(p)
	}
	h.pruneClaimMisses(now)
}
