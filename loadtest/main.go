// Load test for the notes API.
//
// It only sends requests whose behavior is the same in every version of the
// server since /whoami was added, so results from different builds (for
// example the single-threaded one and the current one) compare directly:
//
//	go -C loadtest run . -url http://127.0.0.1:8080
//
// Setup registers a user (ignoring "already exists"), logs in and creates a
// note to fetch. Each scenario then runs with -c keep-alive connections for -d
// after a -warmup that isn't measured. Connections are closed between phases:
// a server that handles one connection at a time would otherwise sit on an
// idle one forever.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

type scenario struct {
	name   string
	desc   string
	method string
	path   string
	body   string
	auth   bool
	want   int
}

type result struct {
	ok      int
	lats    []time.Duration
	errs    map[string]int
	elapsed time.Duration
}

func main() {
	base := flag.String("url", "http://127.0.0.1:8080", "server base URL")
	conns := flag.Int("c", 64, "concurrent keep-alive connections")
	dur := flag.Duration("d", 10*time.Second, "measured duration per scenario")
	warmup := flag.Duration("warmup", time.Second, "unmeasured warmup per scenario")
	timeout := flag.Duration("timeout", 5*time.Second, "per-request timeout")
	only := flag.String("scenarios", "whoami,get,create,login", "comma-separated scenarios to run")
	user := flag.String("user", "loadtest", "username to register and log in as")
	pass := flag.String("password", "loadtest-password", "password for -user")
	flag.Parse()
	*base = strings.TrimRight(*base, "/")

	token, noteID, err := setup(*base, *user, *pass)
	if err != nil {
		fmt.Fprintf(os.Stderr, "setup failed: %v\n(is the server running at %s?)\n", err, *base)
		os.Exit(1)
	}

	credentials := fmt.Sprintf(`{"username":%q,"password":%q}`, *user, *pass)
	all := []scenario{
		{"whoami", "GET /whoami (JWT check, no database)", "GET", "/whoami", "", true, 200},
		{"get", "GET /notes/:id (one indexed read)", "GET", fmt.Sprintf("/notes/%d", noteID), "", true, 200},
		{"create", "POST /notes (one insert)", "POST", "/notes", "load test note", true, 201},
		{"login", "POST /login (Argon2id verify)", "POST", "/login", credentials, false, 200},
	}
	var selected []scenario
	for _, name := range strings.Split(*only, ",") {
		i := slices.IndexFunc(all, func(s scenario) bool { return s.name == strings.TrimSpace(name) })
		if i < 0 {
			fmt.Fprintf(os.Stderr, "unknown scenario %q\n", name)
			os.Exit(2)
		}
		selected = append(selected, all[i])
	}

	fmt.Printf("target %s  connections %d  duration %v (+%v warmup)  timeout %v\n\n",
		*base, *conns, *dur, *warmup, *timeout)
	fmt.Printf("%-7s %-42s %9s %9s %7s %9s %9s %9s %9s\n",
		"name", "request", "req/s", "ok", "errors", "p50", "p90", "p99", "max")

	for _, s := range selected {
		if *warmup > 0 {
			run(*base, token, s, *conns, *warmup, *timeout)
		}
		r := run(*base, token, s, *conns, *dur, *timeout)
		errors := 0
		for _, n := range r.errs {
			errors += n
		}
		fmt.Printf("%-7s %-42s %9.0f %9d %7d %9v %9v %9v %9v\n",
			s.name, s.desc, float64(r.ok)/r.elapsed.Seconds(), r.ok, errors,
			pct(r.lats, 0.50), pct(r.lats, 0.90), pct(r.lats, 0.99), pct(r.lats, 1))
		for kind, n := range r.errs {
			fmt.Printf("%-7s   %d × %s\n", "", n, kind)
		}
	}
}

// setup returns a bearer token and the id of a note that GET can fetch.
func setup(base, user, pass string) (string, int, error) {
	// Fresh connection per request so nothing is left idle on the server.
	client := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	credentials := fmt.Sprintf(`{"username":%q,"password":%q}`, user, pass)

	// May already exist; depending on the version that's a 409 or a dropped connection.
	if resp, err := client.Post(base+"/user", "application/json", strings.NewReader(credentials)); err == nil {
		resp.Body.Close()
	}

	var login struct {
		Token string `json:"token"`
	}
	if err := call(client, "POST", base+"/login", "", credentials, 200, &login); err != nil {
		return "", 0, fmt.Errorf("login: %w", err)
	}

	var note struct {
		ID int `json:"id"`
	}
	if err := call(client, "POST", base+"/notes", login.Token, "load test target", 201, &note); err != nil {
		return "", 0, fmt.Errorf("create note: %w", err)
	}
	return login.Token, note.ID, nil
}

func call(client *http.Client, method, url, token, body string, want int, out any) error {
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != want {
		return fmt.Errorf("%s %s: status %d: %s", method, url, resp.StatusCode, data)
	}
	return json.Unmarshal(data, out)
}

// run drives s over conns connections for dur. Requests still in flight at
// the deadline are abandoned and not counted, so a stalled server can't
// stretch the measurement window.
func run(base, token string, s scenario, conns int, dur, timeout time.Duration) result {
	transport := &http.Transport{
		MaxIdleConns:        conns,
		MaxIdleConnsPerHost: conns,
		MaxConnsPerHost:     conns,
		DisableCompression:  true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: timeout}

	start := time.Now()
	ctx, cancel := context.WithDeadline(context.Background(), start.Add(dur))
	defer cancel()

	var mu sync.Mutex
	total := result{errs: map[string]int{}}
	var wg sync.WaitGroup
	for range conns {
		wg.Go(func() {
			lats := make([]time.Duration, 0, 4096)
			errs := map[string]int{}
			body := []byte(s.body)
			for ctx.Err() == nil {
				req, _ := http.NewRequestWithContext(ctx, s.method, base+s.path, bytes.NewReader(body))
				req.Header.Set("content-type", "application/json")
				if s.auth {
					req.Header.Set("authorization", "Bearer "+token)
				}
				t := time.Now()
				resp, err := client.Do(req)
				if err == nil {
					_, err = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
				if ctx.Err() != nil {
					break // cut off by the deadline
				}
				switch {
				case err != nil:
					errs[classify(err)]++
				case resp.StatusCode != s.want:
					errs[fmt.Sprintf("status %d (want %d)", resp.StatusCode, s.want)]++
				default:
					lats = append(lats, time.Since(t))
				}
			}
			mu.Lock()
			total.ok += len(lats)
			total.lats = append(total.lats, lats...)
			for k, v := range errs {
				total.errs[k] += v
			}
			mu.Unlock()
		})
	}
	wg.Wait()
	total.elapsed = dur
	sort.Slice(total.lats, func(i, j int) bool { return total.lats[i] < total.lats[j] })
	return total
}

func classify(err error) string {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "Client.Timeout"):
		return "timeout"
	case strings.Contains(msg, "connection reset"):
		return "connection reset"
	case strings.Contains(msg, "connection refused"):
		return "connection refused"
	case strings.Contains(msg, "EOF"):
		return "connection closed"
	}
	if len(msg) > 80 {
		msg = msg[:80]
	}
	return msg
}

func pct(sorted []time.Duration, p float64) string {
	if len(sorted) == 0 {
		return "-"
	}
	d := sorted[int(float64(len(sorted)-1)*p)]
	switch {
	case d < time.Millisecond:
		return d.Round(time.Microsecond).String()
	case d < time.Second:
		return d.Round(10 * time.Microsecond).String()
	}
	return d.Round(time.Millisecond).String()
}
