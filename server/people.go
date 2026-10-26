package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxSessionsPerPerson = 8
	maxSessionsGlobal    = 64
	maxPeople            = 400
	enrollPerHour        = 30
	enrollPerIPHour      = 8
	pairLifetime         = 10 * time.Minute
)

type person struct {
	Token   string `json:"token"`
	User    string `json:"user"`
	Home    string `json:"home"`
	UID     uint32 `json:"uid"`
	GID     uint32 `json:"gid"`
	Created int64  `json:"created"`
	// LastSeen is when this person last connected or used the API.
	LastSeen int64 `json:"lastSeen,omitempty"`
	// loaded is when this server read the person from disk. Nobody expires
	// until a full idle period after a start, whatever people.json says.
	loaded int64
}

type enrollHit struct {
	ip string
	at time.Time
}

type pairTicket struct {
	token string
	exp   time.Time
}

func (p *person) jail(cwd string) (string, error) {
	home := filepath.Clean(p.Home)
	if strings.TrimSpace(cwd) == "" {
		return home, nil
	}
	abs := cwd
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(home, abs)
	}
	abs = filepath.Clean(abs)
	sep := string(os.PathSeparator)
	if abs != home && !strings.HasPrefix(abs, home+sep) {
		return "", errors.New("that directory is outside this session")
	}
	return abs, nil
}

func (h *hub) person(token string) *person {
	if token == "" {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	p := h.people[token]
	if p != nil {
		if now := time.Now().Unix(); p.LastSeen != now {
			p.LastSeen = now
			h.seenChanged = true
		}
	}
	return p
}

func (h *hub) known(token string) bool {
	return h.person(token) != nil
}

var stateDir = "/var/lib/aether"

// loadPeople refuses to go on when people.json is there but unreadable:
// starting empty would hand out fresh accounts while everyone's real ones sit
// in a file that the next save would overwrite.
func (h *hub) loadPeople() error {
	h.people = map[string]*person{}
	h.devices = map[string]bool{}
	h.pairs = map[string]pairTicket{}
	h.claimMiss = map[string][]time.Time{}
	var file struct {
		People []*person `json:"people"`
	}
	path := filepath.Join(stateDir, "people.json")
	b, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &file); err != nil {
			return fmt.Errorf("%s is damaged, fix or move it before starting: %w", path, err)
		}
	case !errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("could not read %s: %w", path, err)
	}
	now := time.Now().Unix()
	for _, p := range file.People {
		if p == nil || p.Token == "" || p.User == "" || p.Home == "" {
			continue
		}
		if u, err := user.Lookup(p.User); err == nil {
			if uid, e1 := strconv.ParseUint(u.Uid, 10, 32); e1 == nil {
				p.UID = uint32(uid)
			}
			if gid, e2 := strconv.ParseUint(u.Gid, 10, 32); e2 == nil {
				p.GID = uint32(gid)
			}
		}
		if p.LastSeen == 0 {
			p.LastSeen = now
		}
		p.loaded = now
		h.people[p.Token] = p
	}
	if b, err := os.ReadFile(filepath.Join(stateDir, "devices")); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			token := strings.TrimSpace(line)
			if token == "" {
				continue
			}
			h.devices[token] = true
			if h.people[token] != nil {
				continue
			}
			if _, err := h.provision(token); err != nil {
				continue
			}
		}
	}
	return nil
}

func (h *hub) savePeople() {
	h.mu.Lock()
	list := make([]*person, 0, len(h.people))
	for _, p := range h.people {
		copy := *p
		list = append(list, &copy)
	}
	h.mu.Unlock()
	body, err := json.MarshalIndent(struct {
		People []*person `json:"people"`
	}{People: list}, "", "  ")
	if err != nil {
		return
	}
	_ = os.MkdirAll(stateDir, 0o700)
	path := filepath.Join(stateDir, "people.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(body, '\n'), 0o600); err != nil {
		log.Printf("saving people: %v", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("saving people: %v", err)
	}
}

func (h *hub) allowEnroll(ip string, now time.Time) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.people) >= maxPeople {
		return false
	}
	cutoff := now.Add(-time.Hour)
	kept := h.enrolls[:0]
	global := 0
	local := 0
	for _, hit := range h.enrolls {
		if hit.at.Before(cutoff) {
			continue
		}
		kept = append(kept, hit)
		global++
		if hit.ip == ip {
			local++
		}
	}
	h.enrolls = kept
	if global >= enrollPerHour || local >= enrollPerIPHour {
		return false
	}
	h.enrolls = append(h.enrolls, enrollHit{ip: ip, at: now})
	return true
}

func (h *hub) enroll(ip string) (*person, error) {
	if !h.allowEnroll(ip, time.Now()) {
		return nil, errors.New("Cloud is not taking new people right now. Try again in a little while.")
	}
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return nil, err
	}
	token := hex.EncodeToString(buf)
	p, err := h.provision(token)
	if err != nil {
		return nil, err
	}
	h.savePeople()
	return p, nil
}

func (h *hub) provision(token string) (*person, error) {
	name := "ae" + token[:8]
	home := filepath.Join(stateDir, "homes", name)
	if err := makeUser(name, home); err != nil {
		return nil, err
	}
	u, err := user.Lookup(name)
	if err != nil {
		return nil, err
	}
	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	if err != nil {
		return nil, err
	}
	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return nil, err
	}
	p := &person{
		Token: token, User: name, Home: home,
		UID: uint32(uid), GID: uint32(gid), Created: time.Now().Unix(), LastSeen: time.Now().Unix(),
	}
	h.mu.Lock()
	h.people[token] = p
	h.mu.Unlock()
	return p, nil
}

func makeUser(name, home string) error {
	if _, err := user.Lookup(name); err != nil {
		if os.Geteuid() != 0 {
			return errors.New("the session server has to run as root to keep people separated")
		}
		if err := os.MkdirAll(filepath.Dir(home), 0o755); err != nil {
			return err
		}
		cmd := exec.Command("useradd", "--create-home", "--home-dir", home, "--shell", "/bin/bash", "--user-group", name)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return errors.New(strings.TrimSpace(string(out)))
		}
	}
	_ = os.Chmod(home, 0o700)
	return nil
}

func (h *hub) sessionCounts(owner string) (own, all int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, s := range h.sessions {
		all++
		if s.owner == owner {
			own++
		}
	}
	return own, all
}

var pairAlphabet = []byte("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

func newPairCode() string {
	buf := make([]byte, 8)
	_, _ = rand.Read(buf)
	var b strings.Builder
	for i := 0; i < 8; i++ {
		if i == 4 {
			b.WriteByte('-')
		}
		b.WriteByte(pairAlphabet[int(buf[i])%len(pairAlphabet)])
	}
	return b.String()
}

func normalizeCode(code string) string {
	return strings.ToUpper(strings.TrimSpace(code))
}

func (h *hub) issuePair(token string) (string, time.Time, error) {
	if !h.known(token) {
		return "", time.Time{}, errors.New("unauthorized")
	}
	code := newPairCode()
	exp := time.Now().Add(pairLifetime)
	h.mu.Lock()
	for existing, ticket := range h.pairs {
		if ticket.exp.Before(time.Now()) || ticket.token == token {
			delete(h.pairs, existing)
		}
	}
	h.pairs[code] = pairTicket{token: token, exp: exp}
	h.mu.Unlock()
	return code, exp, nil
}

func (h *hub) claimPair(code, ip string) (string, error) {
	code = normalizeCode(code)
	if code == "" {
		return "", errors.New("that code does not work")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.claimMiss) >= maxClaimMissIPs {
		h.pruneClaimMissesLocked(time.Now())
	}
	cutoff := time.Now().Add(-claimWindow)
	misses := h.claimMiss[ip][:0]
	for _, at := range h.claimMiss[ip] {
		if at.After(cutoff) {
			misses = append(misses, at)
		}
	}
	all := h.claimAll[:0]
	for _, at := range h.claimAll {
		if at.After(cutoff) {
			all = append(all, at)
		}
	}
	h.claimAll = all
	if len(misses) >= 8 || len(all) >= maxClaimMissesGlobal {
		h.claimMiss[ip] = misses
		return "", errors.New("too many wrong codes")
	}
	ticket, ok := h.pairs[code]
	if !ok || ticket.exp.Before(time.Now()) {
		delete(h.pairs, code)
		h.claimMiss[ip] = append(misses, time.Now())
		h.claimAll = append(h.claimAll, time.Now())
		return "", errors.New("that code does not work")
	}
	delete(h.pairs, code)
	if len(misses) == 0 {
		delete(h.claimMiss, ip)
	} else {
		h.claimMiss[ip] = misses
	}
	return ticket.token, nil
}

const (
	claimWindow     = 10 * time.Minute
	maxClaimMissIPs = 4096
	// maxClaimMissesGlobal caps wrong codes from everyone together. Cloud
	// shells reach the server over loopback, where forwarding headers are
	// believed, so the per-address limit alone can be dodged by making up
	// addresses. This keeps guessing a live code hopeless either way.
	maxClaimMissesGlobal = 200
)

func (h *hub) pruneClaimMisses(now time.Time) {
	h.mu.Lock()
	h.pruneClaimMissesLocked(now)
	h.mu.Unlock()
}

// pruneClaimMissesLocked forgets addresses whose wrong guesses have aged out.
// If a flood of fresh addresses still leaves too many, the quietest half go.
func (h *hub) pruneClaimMissesLocked(now time.Time) {
	cutoff := now.Add(-claimWindow)
	for ip, times := range h.claimMiss {
		if len(times) == 0 || !times[len(times)-1].After(cutoff) {
			delete(h.claimMiss, ip)
		}
	}
	if len(h.claimMiss) < maxClaimMissIPs {
		return
	}
	ips := make([]string, 0, len(h.claimMiss))
	for ip := range h.claimMiss {
		ips = append(ips, ip)
	}
	sort.Slice(ips, func(i, j int) bool {
		a, b := h.claimMiss[ips[i]], h.claimMiss[ips[j]]
		return a[len(a)-1].Before(b[len(b)-1])
	})
	for _, ip := range ips[:len(ips)-maxClaimMissIPs/2] {
		delete(h.claimMiss, ip)
	}
}

// clientIP names the caller for rate limits. Forwarding headers are only
// believed when the request came from this machine, which is where the tunnel
// runs; anyone else could set them to dodge the limits.
func clientIP(remoteAddr, forwarded, cloudflare string) string {
	host := remoteAddr
	if h, _, err := net.SplitHostPort(remoteAddr); err == nil {
		host = h
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if ip := strings.TrimSpace(cloudflare); ip != "" {
			return ip
		}
		if forwarded != "" {
			parts := strings.Split(forwarded, ",")
			if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
				return last
			}
		}
	}
	if host == "" {
		return "unknown"
	}
	return host
}

const (
	defaultPublicURLFile = "/etc/aether/public.url"
	defaultPublicEnvFile = "/etc/aether/public.env"
)

var (
	publicURLFile = defaultPublicURLFile
	publicEnvFile = defaultPublicEnvFile
)

// publicURL is read fresh on every call. The tunnel gets a new address each
// time it restarts and rewrites these files, while the environment was fixed
// when the server started, so the files win.
func publicURL() string {
	if b, err := os.ReadFile(publicURLFile); err == nil {
		if raw := strings.TrimSpace(string(b)); raw != "" {
			return raw
		}
	}
	if b, err := os.ReadFile(publicEnvFile); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			key, val, ok := strings.Cut(strings.TrimSpace(line), "=")
			if ok && strings.TrimSpace(key) == "AETHER_PUBLIC_URL" {
				if raw := strings.Trim(strings.TrimSpace(val), `"'`); raw != "" {
					return raw
				}
			}
		}
	}
	return strings.TrimSpace(os.Getenv("AETHER_PUBLIC_URL"))
}

func publicEndpoint() (web, ws, host string) {
	raw := strings.TrimRight(publicURL(), "/")
	if raw == "" {
		return "", "", ""
	}
	scheme, rest, ok := strings.Cut(raw, "://")
	if !ok || rest == "" {
		return "", "", ""
	}
	hostport, _, _ := strings.Cut(rest, "/")
	name := hostport
	if h, _, ok := strings.Cut(hostport, ":"); ok {
		name = h
	}
	wsScheme := "wss"
	if scheme == "http" {
		wsScheme = "ws"
	}
	return raw, wsScheme + "://" + hostport + "/ws", name
}

// saveMu serializes people.json writes from enroll.
var saveMu sync.Mutex

func (h *hub) enrollSaved(ip string) (*person, error) {
	saveMu.Lock()
	defer saveMu.Unlock()
	return h.enroll(ip)
}
