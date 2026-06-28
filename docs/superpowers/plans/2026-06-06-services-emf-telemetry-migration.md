# Services Telemetry Migration (OTel SDK + /metrics → CloudWatch EMF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dead OTel SDK push pipeline and the now-orphaned Prometheus `/metrics` endpoints from all four services, replacing per-service RED telemetry with CloudWatch Embedded Metric Format (EMF) emitted to stdout.

**Architecture:** Each service stops pushing OTLP to the removed collector and stops exposing a scrape endpoint. Instead, an HTTP middleware (Go/Fiber and Next.js) writes one EMF JSON object per request to stdout. In prod, CloudWatch Logs auto-extracts `RequestCount`/`RequestLatency`/`ErrorCount` into metrics; in dev the same lines go to LocalStack (Plan 2). The transcode worker emits a job-level EMF object instead of an OTel span. This is **Plan 1 of 2**; Plan 2 covers infra (LocalStack/Grafana dev + CloudWatch Terraform prod + archiving `streaming-telemetry`).

**Tech Stack:** Go 1.x + Fiber v2 (ingest, distribution, transcode), Next.js 14 + TypeScript (upload). EMF is plain JSON — no new runtime dependencies.

**Repos touched (separate git repos — commit from inside each, per polyrepo topology):** `streaming-ingest` (branch `main`), `streaming-distribution`, `streaming-transcode`, `streaming-platform-upload`. Verify each repo's default branch with `git -C <repo> branch --show-current` before committing; commit on the default branch (user-approved policy).

**EMF contract (identical across services):**
```json
{
  "_aws": {
    "Timestamp": 1717689600000,
    "CloudWatchMetrics": [{
      "Namespace": "VOD/<service>",
      "Dimensions": [["service", "route", "method"]],
      "Metrics": [
        {"Name": "RequestCount",   "Unit": "Count"},
        {"Name": "RequestLatency", "Unit": "Milliseconds"},
        {"Name": "ErrorCount",     "Unit": "Count"}
      ]
    }]
  },
  "service": "<service>", "route": "<route>", "method": "<method>",
  "RequestCount": 1, "RequestLatency": 42.5, "ErrorCount": 0
}
```
`ErrorCount` = 1 when HTTP status >= 500, else 0. `route` is the low-cardinality route label.

---

## File structure (what changes)

**streaming-ingest** (and identical shape in **streaming-distribution**)
- Create: `internal/telemetry/emf.go` — EMF emitter + Fiber middleware.
- Create: `internal/telemetry/emf_test.go` — emitter/middleware tests.
- Delete: `internal/otel/setup.go` (whole `internal/otel/` dir).
- Modify: `cmd/api/main.go` — drop `intotel.Init`, `otelfiber`, `fiberprometheus`; wire `telemetry.Middleware`.
- Modify: `go.mod` / `go.sum` — drop otel + fiberprometheus + otelfiber deps (`go mod tidy`).

**streaming-transcode**
- Create: `internal/telemetry/emf.go` — `EmitJob(...)` job-level EMF.
- Create: `internal/telemetry/emf_test.go`.
- Delete: `internal/otel/setup.go`.
- Modify: `cmd/worker/main.go` — drop `intotel.Init`.
- Modify: `internal/worker/processor.go` — drop OTel span, emit job EMF.
- Modify: `go.mod` / `go.sum` — `go mod tidy`.

**streaming-platform-upload**
- Create: `src/lib/telemetry/emf.ts` — `withEmf(route, handler)` wrapper + emitter.
- Create: `src/lib/telemetry/__tests__/emf.test.ts`.
- Delete: `instrumentation.ts`, `src/lib/metrics.ts`, `src/app/api/metrics/` (route + `__tests__`).
- Modify: `next.config.js` — remove `instrumentationHook`.
- Modify: `src/app/api/integrate/route.ts`, `src/app/api/videos/route.ts`, `src/app/api/upload/route.ts` — swap `withMetrics` → `withEmf`.
- Modify: `package.json` — remove `@opentelemetry/*` + `prom-client`.

---

## TASK 1: streaming-ingest — EMF emitter + middleware

**Files:**
- Create: `streaming-ingest/internal/telemetry/emf.go`
- Test: `streaming-ingest/internal/telemetry/emf_test.go`

- [ ] **Step 1: Write the failing test**

`streaming-ingest/internal/telemetry/emf_test.go`:
```go
package telemetry

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

func TestEmitterWritesValidEMF(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Service: "streaming-ingest", Out: &buf, Now: func() time.Time { return time.UnixMilli(1717689600000) }}

	e.Emit("/api/v1/events", "POST", 201, 42*time.Millisecond)

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, buf.String())
	}
	if got["RequestCount"].(float64) != 1 {
		t.Errorf("RequestCount = %v, want 1", got["RequestCount"])
	}
	if got["ErrorCount"].(float64) != 0 {
		t.Errorf("ErrorCount = %v, want 0 for status 201", got["ErrorCount"])
	}
	if got["RequestLatency"].(float64) != 42 {
		t.Errorf("RequestLatency = %v, want 42", got["RequestLatency"])
	}
	if got["service"] != "streaming-ingest" || got["route"] != "/api/v1/events" || got["method"] != "POST" {
		t.Errorf("dimensions wrong: %v", got)
	}
	aws := got["_aws"].(map[string]any)
	cwm := aws["CloudWatchMetrics"].([]any)[0].(map[string]any)
	if cwm["Namespace"] != "VOD/streaming-ingest" {
		t.Errorf("Namespace = %v", cwm["Namespace"])
	}
}

func TestEmitterCountsServerErrors(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Service: "streaming-ingest", Out: &buf, Now: time.Now}
	e.Emit("/x", "GET", 503, time.Millisecond)

	var got map[string]any
	_ = json.Unmarshal(buf.Bytes(), &got)
	if got["ErrorCount"].(float64) != 1 {
		t.Errorf("ErrorCount = %v, want 1 for status 503", got["ErrorCount"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd streaming-ingest && go test ./internal/telemetry/`
Expected: FAIL — `package .../internal/telemetry` does not compile (no `Emitter`).

- [ ] **Step 3: Write minimal implementation**

`streaming-ingest/internal/telemetry/emf.go`:
```go
// Package telemetry emits CloudWatch Embedded Metric Format (EMF) lines to stdout.
// CloudWatch Logs extracts RequestCount/RequestLatency/ErrorCount into metrics; no
// collector or scrape endpoint is involved.
package telemetry

import (
	"encoding/json"
	"io"
	"os"
	"time"

	"github.com/gofiber/fiber/v2"
)

// Emitter writes one EMF JSON object per call to Out.
type Emitter struct {
	Service string
	Out     io.Writer
	Now     func() time.Time
}

// New returns an Emitter writing to stdout with the real clock.
func New(service string) *Emitter {
	return &Emitter{Service: service, Out: os.Stdout, Now: time.Now}
}

// Emit writes a single RED EMF record.
func (e *Emitter) Emit(route, method string, status int, latency time.Duration) {
	errCount := 0
	if status >= 500 {
		errCount = 1
	}
	record := map[string]any{
		"_aws": map[string]any{
			"Timestamp": e.Now().UnixMilli(),
			"CloudWatchMetrics": []map[string]any{{
				"Namespace":  "VOD/" + e.Service,
				"Dimensions": [][]string{{"service", "route", "method"}},
				"Metrics": []map[string]string{
					{"Name": "RequestCount", "Unit": "Count"},
					{"Name": "RequestLatency", "Unit": "Milliseconds"},
					{"Name": "ErrorCount", "Unit": "Count"},
				},
			}},
		},
		"service":        e.Service,
		"route":          route,
		"method":         method,
		"RequestCount":   1,
		"RequestLatency": float64(latency.Microseconds()) / 1000.0,
		"ErrorCount":     errCount,
	}
	b, err := json.Marshal(record)
	if err != nil {
		return
	}
	_, _ = e.Out.Write(append(b, '\n'))
}

// Middleware returns a Fiber handler that emits one EMF record per request.
// route uses the matched route pattern (low cardinality).
func (e *Emitter) Middleware() fiber.Handler {
	return func(c *fiber.Ctx) error {
		start := e.Now()
		err := c.Next()
		route := c.Route().Path
		if route == "" {
			route = c.Path()
		}
		e.Emit(route, c.Method(), c.Response().StatusCode(), e.Now().Sub(start))
		return err
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd streaming-ingest && go test ./internal/telemetry/`
Expected: PASS (ok streaming-ingest/internal/telemetry).

- [ ] **Step 5: Commit**

```bash
cd streaming-ingest
git add internal/telemetry/emf.go internal/telemetry/emf_test.go
git commit -m "feat(telemetry): add CloudWatch EMF emitter + Fiber middleware"
```

## TASK 2: streaming-ingest — wire EMF, remove OTel + /metrics

**Files:**
- Modify: `streaming-ingest/cmd/api/main.go`
- Delete: `streaming-ingest/internal/otel/setup.go`
- Modify: `streaming-ingest/go.mod`, `go.sum`

- [ ] **Step 1: Replace `newApp()` to use the EMF middleware**

In `streaming-ingest/cmd/api/main.go`, replace the `newApp` function (lines ~122-132) with:
```go
func newApp() *fiber.App {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})
	app.Use(logger.New())
	app.Use(telemetry.New("streaming-ingest").Middleware())
	return app
}
```

- [ ] **Step 2: Remove the OTel init block in `main()`**

Delete lines ~41-50 (the `otelShutdown, err := intotel.Init(...)` block and its `defer`).

- [ ] **Step 3: Fix imports**

In the import block: remove `intotel "streaming-ingest/internal/otel"`, `fiberprometheus "github.com/ansrivas/fiberprometheus/v2"`, and `"github.com/gofiber/contrib/otelfiber/v2"`. Add `"streaming-ingest/internal/telemetry"`. Remove `"context"` and `"time"` only if no longer referenced (they are still used by mongo/rabbit retry + shutdown — keep them).

- [ ] **Step 4: Delete the otel package and tidy modules**

```bash
cd streaming-ingest
rm -rf internal/otel
go mod tidy
```

- [ ] **Step 5: Build + test the whole module**

Run: `cd streaming-ingest && go build ./... && go test ./...`
Expected: build succeeds; all tests PASS. (If any test referenced `/metrics`, see Task 3.)

- [ ] **Step 6: Verify no stragglers**

Run: `cd streaming-ingest && grep -rn "otel\|fiberprometheus\|/metrics" --include="*.go" .`
Expected: no matches.

- [ ] **Step 7: Commit**

```bash
cd streaming-ingest
git add cmd/api/main.go go.mod go.sum
git rm -r internal/otel
git commit -m "refactor(telemetry): drop OTel SDK + /metrics, emit EMF middleware"
```

## TASK 3: streaming-ingest — drop /metrics from main_test.go

**Files:**
- Modify: `streaming-ingest/cmd/api/main_test.go`

- [ ] **Step 1: Find any /metrics or otel assertions**

Run: `cd streaming-ingest && grep -n "/metrics\|prometheus\|otel" cmd/api/main_test.go`
Expected: lists the assertions to remove (if any).

- [ ] **Step 2: Remove those test cases/assertions**

Delete any test that hits `GET /metrics` or asserts Prometheus output. Leave all other route tests intact. If a test asserts an EMF side effect, none is required here (covered by Task 1).

- [ ] **Step 3: Run tests**

Run: `cd streaming-ingest && go test ./...`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd streaming-ingest
git add cmd/api/main_test.go
git commit -m "test(telemetry): remove /metrics endpoint assertions"
```

## TASK 4: streaming-distribution — EMF emitter + middleware

**Files:**
- Create: `streaming-distribution/internal/telemetry/emf.go`
- Test: `streaming-distribution/internal/telemetry/emf_test.go`

- [ ] **Step 1: Write the failing test**

Copy the test from Task 1 Step 1 verbatim into `streaming-distribution/internal/telemetry/emf_test.go`, replacing the package-name string literal `"streaming-ingest"` with `"streaming-distribution"` and the Namespace expectation `"VOD/streaming-ingest"` with `"VOD/streaming-distribution"`. (Repeated in full because tasks may be read out of order:)
```go
package telemetry

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

func TestEmitterWritesValidEMF(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Service: "streaming-distribution", Out: &buf, Now: func() time.Time { return time.UnixMilli(1717689600000) }}
	e.Emit("/api/v1/manifest/:videoId", "GET", 200, 42*time.Millisecond)

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, buf.String())
	}
	if got["RequestCount"].(float64) != 1 {
		t.Errorf("RequestCount = %v, want 1", got["RequestCount"])
	}
	if got["ErrorCount"].(float64) != 0 {
		t.Errorf("ErrorCount = %v, want 0 for status 200", got["ErrorCount"])
	}
	aws := got["_aws"].(map[string]any)
	cwm := aws["CloudWatchMetrics"].([]any)[0].(map[string]any)
	if cwm["Namespace"] != "VOD/streaming-distribution" {
		t.Errorf("Namespace = %v", cwm["Namespace"])
	}
}

func TestEmitterCountsServerErrors(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Service: "streaming-distribution", Out: &buf, Now: time.Now}
	e.Emit("/x", "GET", 503, time.Millisecond)
	var got map[string]any
	_ = json.Unmarshal(buf.Bytes(), &got)
	if got["ErrorCount"].(float64) != 1 {
		t.Errorf("ErrorCount = %v, want 1 for status 503", got["ErrorCount"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd streaming-distribution && go test ./internal/telemetry/`
Expected: FAIL — package does not compile.

- [ ] **Step 3: Write the implementation**

Create `streaming-distribution/internal/telemetry/emf.go` with the **exact same code as Task 1 Step 3**, except change the doc comment if desired. The code is package-name agnostic (Service is passed at construction), so it is byte-identical apart from being in the `streaming-distribution` module. Paste the full Task 1 Step 3 file content here.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd streaming-distribution && go test ./internal/telemetry/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd streaming-distribution
git add internal/telemetry/emf.go internal/telemetry/emf_test.go
git commit -m "feat(telemetry): add CloudWatch EMF emitter + Fiber middleware"
```

## TASK 5: streaming-distribution — wire EMF, remove OTel + /metrics

**Files:**
- Modify: `streaming-distribution/cmd/api/main.go`
- Delete: `streaming-distribution/internal/otel/setup.go`
- Modify: `streaming-distribution/go.mod`, `go.sum`, `cmd/api/main_test.go`

- [ ] **Step 1: Replace `newApp()`**

Replace `newApp` (lines ~99-112) with:
```go
func newApp() *fiber.App {
	app := fiber.New(fiber.Config{DisableStartupMessage: true})
	app.Use(logger.New())
	app.Use(cors.New(cors.Config{
		AllowOrigins: "*",
		AllowMethods: "GET,OPTIONS",
		AllowHeaders: "X-API-Key,Content-Type",
	}))
	app.Use(telemetry.New("streaming-distribution").Middleware())
	return app
}
```

- [ ] **Step 2: Remove OTel init block**

Delete the `otelShutdown, err := intotel.Init(...)` block + its `defer` (lines ~40-49).

- [ ] **Step 3: Fix imports**

Remove `intotel "streaming-distribution/internal/otel"`, `fiberprometheus "github.com/ansrivas/fiberprometheus/v2"`, `"github.com/gofiber/contrib/otelfiber/v2"`. Add `"streaming-distribution/internal/telemetry"`.

- [ ] **Step 4: Delete otel package + tidy**

```bash
cd streaming-distribution
rm -rf internal/otel
go mod tidy
```

- [ ] **Step 5: Remove /metrics assertions from main_test.go**

Run: `cd streaming-distribution && grep -n "/metrics\|prometheus\|otel" cmd/api/main_test.go` and delete any matching test cases/assertions.

- [ ] **Step 6: Build + test**

Run: `cd streaming-distribution && go build ./... && go test ./...`
Expected: build OK, all PASS.

- [ ] **Step 7: Commit**

```bash
cd streaming-distribution
git add cmd/api/main.go cmd/api/main_test.go go.mod go.sum
git rm -r internal/otel
git commit -m "refactor(telemetry): drop OTel SDK + /metrics, emit EMF middleware"
```

## TASK 6: streaming-transcode — job EMF emitter

**Files:**
- Create: `streaming-transcode/internal/telemetry/emf.go`
- Test: `streaming-transcode/internal/telemetry/emf_test.go`

- [ ] **Step 1: Write the failing test**

`streaming-transcode/internal/telemetry/emf_test.go`:
```go
package telemetry

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

func TestEmitJobWritesValidEMF(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Out: &buf, Now: func() time.Time { return time.UnixMilli(1717689600000) }}

	e.EmitJob("vid123", "success", 12500*time.Millisecond)

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("not valid JSON: %v\n%s", err, buf.String())
	}
	if got["JobCount"].(float64) != 1 {
		t.Errorf("JobCount = %v, want 1", got["JobCount"])
	}
	if got["JobDuration"].(float64) != 12500 {
		t.Errorf("JobDuration = %v, want 12500", got["JobDuration"])
	}
	if got["FailureCount"].(float64) != 0 {
		t.Errorf("FailureCount = %v, want 0 for success", got["FailureCount"])
	}
	if got["result"] != "success" || got["video_id"] != "vid123" {
		t.Errorf("dims wrong: %v", got)
	}
	aws := got["_aws"].(map[string]any)
	cwm := aws["CloudWatchMetrics"].([]any)[0].(map[string]any)
	if cwm["Namespace"] != "VOD/streaming-transcode" {
		t.Errorf("Namespace = %v", cwm["Namespace"])
	}
}

func TestEmitJobCountsFailures(t *testing.T) {
	var buf bytes.Buffer
	e := &Emitter{Out: &buf, Now: time.Now}
	e.EmitJob("v", "failed", time.Second)
	var got map[string]any
	_ = json.Unmarshal(buf.Bytes(), &got)
	if got["FailureCount"].(float64) != 1 {
		t.Errorf("FailureCount = %v, want 1", got["FailureCount"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd streaming-transcode && go test ./internal/telemetry/`
Expected: FAIL — package does not compile.

- [ ] **Step 3: Write the implementation**

`streaming-transcode/internal/telemetry/emf.go`:
```go
// Package telemetry emits CloudWatch EMF job records to stdout for the transcode worker.
package telemetry

import (
	"encoding/json"
	"io"
	"os"
	"time"
)

type Emitter struct {
	Out io.Writer
	Now func() time.Time
}

func New() *Emitter { return &Emitter{Out: os.Stdout, Now: time.Now} }

// EmitJob writes a single job-level EMF record. result is "success" or "failed".
func (e *Emitter) EmitJob(videoID, result string, dur time.Duration) {
	failure := 0
	if result != "success" {
		failure = 1
	}
	record := map[string]any{
		"_aws": map[string]any{
			"Timestamp": e.Now().UnixMilli(),
			"CloudWatchMetrics": []map[string]any{{
				"Namespace":  "VOD/streaming-transcode",
				"Dimensions": [][]string{{"result"}},
				"Metrics": []map[string]string{
					{"Name": "JobCount", "Unit": "Count"},
					{"Name": "JobDuration", "Unit": "Milliseconds"},
					{"Name": "FailureCount", "Unit": "Count"},
				},
			}},
		},
		"video_id":     videoID,
		"result":       result,
		"JobCount":     1,
		"JobDuration":  float64(dur.Microseconds()) / 1000.0,
		"FailureCount": failure,
	}
	b, err := json.Marshal(record)
	if err != nil {
		return
	}
	_, _ = e.Out.Write(append(b, '\n'))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd streaming-transcode && go test ./internal/telemetry/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd streaming-transcode
git add internal/telemetry/emf.go internal/telemetry/emf_test.go
git commit -m "feat(telemetry): add CloudWatch EMF job emitter"
```

## TASK 7: streaming-transcode — remove OTel span + init, emit job EMF

**Files:**
- Modify: `streaming-transcode/cmd/worker/main.go`
- Modify: `streaming-transcode/internal/worker/processor.go`
- Delete: `streaming-transcode/internal/otel/setup.go`
- Modify: `streaming-transcode/go.mod`, `go.sum`

- [ ] **Step 1: Remove OTel init from main.go**

In `streaming-transcode/cmd/worker/main.go`, delete the `otelShutdown, err := intotel.Init(ctx)` block + `defer` (lines ~27-36) and remove the import `intotel "streaming-transcode/internal/otel"`.

- [ ] **Step 2: Replace the OTel span in processor.go**

In `internal/worker/processor.go`, remove imports `"go.opentelemetry.io/otel"`, `"go.opentelemetry.io/otel/attribute"`, `oteltrace "go.opentelemetry.io/otel/trace"`. Replace the span block (lines ~88-96):
```go
	tracer := otel.Tracer("streaming-transcode")
	ctx, jobSpan := tracer.Start(ctx, "transcode.job",
		oteltrace.WithAttributes(
			attribute.String("video_id", event.VideoID),
			attribute.String("job_id", jobID),
			attribute.Int("attempt", attempt),
		),
	)
	defer jobSpan.End()
```
with a deferred EMF emission using the existing `started`/`p.clockNow()` timing already computed two lines below — move `started := p.clockNow()` above and add:
```go
	started := p.clockNow()
	jobResult := "failed"
	defer func() {
		p.telemetry.EmitJob(event.VideoID, jobResult, p.clockNow().Sub(started))
	}()
```
Then set `jobResult = "success"` immediately before each successful `return` in `process` (the `markReady` path and the final success return). (Search for `return p.markReady` and the terminal success `return nil` of `process`.)

- [ ] **Step 3: Add the telemetry emitter to the Processor**

In `internal/worker/processor.go`, add a `telemetry *telemetry.Emitter` field to the `Processor` struct and initialize it in `NewProcessor` (default `telemetry.New()` when not injected). Add import `"streaming-transcode/internal/telemetry"`. If `NewProcessor` takes a `Dependencies` struct, add an optional `Telemetry *telemetry.Emitter` field defaulting to `telemetry.New()` when nil — mirror how `ClockNow` is defaulted.

- [ ] **Step 4: Delete otel package + tidy**

```bash
cd streaming-transcode
rm -rf internal/otel
go mod tidy
```

- [ ] **Step 5: Build + test**

Run: `cd streaming-transcode && go build ./... && go test ./...`
Expected: build OK, all PASS. Fix any `processor_test.go` constructor call that now needs the defaulting path (no new arg required if defaulted internally).

- [ ] **Step 6: Verify no stragglers**

Run: `cd streaming-transcode && grep -rn "go.opentelemetry.io\|intotel" --include="*.go" .`
Expected: no matches.

- [ ] **Step 7: Commit**

```bash
cd streaming-transcode
git add cmd/worker/main.go internal/worker/processor.go go.mod go.sum
git rm -r internal/otel
git commit -m "refactor(telemetry): replace OTel span/init with job EMF emission"
```

## TASK 8: streaming-platform-upload — EMF wrapper

**Files:**
- Create: `streaming-platform-upload/src/lib/telemetry/emf.ts`
- Test: `streaming-platform-upload/src/lib/telemetry/__tests__/emf.test.ts`

- [ ] **Step 1: Write the failing test**

`streaming-platform-upload/src/lib/telemetry/__tests__/emf.test.ts`:
```ts
import { withEmf, emitEmf } from '@/lib/telemetry/emf';

describe('emitEmf', () => {
  it('writes a valid EMF record to the sink', () => {
    const lines: string[] = [];
    emitEmf({ route: '/api/upload', method: 'POST', status: 200, latencyMs: 12.5 }, (s) => lines.push(s));
    const rec = JSON.parse(lines[0]);
    expect(rec.RequestCount).toBe(1);
    expect(rec.ErrorCount).toBe(0);
    expect(rec.RequestLatency).toBe(12.5);
    expect(rec.service).toBe('streaming-platform-upload');
    expect(rec.route).toBe('/api/upload');
    expect(rec._aws.CloudWatchMetrics[0].Namespace).toBe('VOD/streaming-platform-upload');
  });

  it('counts server errors', () => {
    const lines: string[] = [];
    emitEmf({ route: '/x', method: 'GET', status: 502, latencyMs: 1 }, (s) => lines.push(s));
    expect(JSON.parse(lines[0]).ErrorCount).toBe(1);
  });
});

describe('withEmf', () => {
  it('wraps a handler and emits one record', async () => {
    const lines: string[] = [];
    const handler = withEmf('/api/videos', async () => new Response('ok', { status: 201 }), (s) => lines.push(s));
    const res = await handler(new Request('http://x/api/videos', { method: 'GET' }));
    expect(res.status).toBe(201);
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0]).route).toBe('/api/videos');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd streaming-platform-upload && npx jest --testPathPattern="telemetry/emf"`
Expected: FAIL — cannot find module `@/lib/telemetry/emf`.

- [ ] **Step 3: Write the implementation**

`streaming-platform-upload/src/lib/telemetry/emf.ts`:
```ts
const SERVICE = 'streaming-platform-upload';

export type EmfInput = { route: string; method: string; status: number; latencyMs: number };
type Sink = (line: string) => void;

const defaultSink: Sink = (line) => process.stdout.write(line + '\n');

/** Emits one CloudWatch EMF record. CloudWatch Logs extracts the metrics; no scrape endpoint. */
export function emitEmf(input: EmfInput, sink: Sink = defaultSink): void {
  const record = {
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: [
        {
          Namespace: `VOD/${SERVICE}`,
          Dimensions: [['service', 'route', 'method']],
          Metrics: [
            { Name: 'RequestCount', Unit: 'Count' },
            { Name: 'RequestLatency', Unit: 'Milliseconds' },
            { Name: 'ErrorCount', Unit: 'Count' },
          ],
        },
      ],
    },
    service: SERVICE,
    route: input.route,
    method: input.method,
    RequestCount: 1,
    RequestLatency: input.latencyMs,
    ErrorCount: input.status >= 500 ? 1 : 0,
  };
  sink(JSON.stringify(record));
}

/**
 * Wraps an app-router handler to emit a RED EMF record per request.
 * Drop-in replacement for the old withMetrics(route, handler).
 */
export function withEmf<Req extends Request = Request, Ctx = unknown>(
  route: string,
  handler: (req: Req, ctx?: Ctx) => Promise<Response> | Response,
  sink: Sink = defaultSink,
): (req: Req, ctx?: Ctx) => Promise<Response> {
  return async (req: Req, ctx?: Ctx): Promise<Response> => {
    const start = process.hrtime.bigint();
    let status = 500;
    try {
      const res = await handler(req, ctx);
      status = res.status;
      return res;
    } finally {
      const latencyMs = Number(process.hrtime.bigint() - start) / 1e6;
      emitEmf({ route, method: req.method, status, latencyMs }, sink);
    }
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd streaming-platform-upload && npx jest --testPathPattern="telemetry/emf"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd streaming-platform-upload
git add src/lib/telemetry/emf.ts src/lib/telemetry/__tests__/emf.test.ts
git commit -m "feat(telemetry): add CloudWatch EMF wrapper for route handlers"
```

## TASK 9: streaming-platform-upload — swap routes to withEmf, delete old telemetry

**Files:**
- Modify: `src/app/api/integrate/route.ts`, `src/app/api/videos/route.ts`, `src/app/api/upload/route.ts`
- Delete: `instrumentation.ts`, `src/lib/metrics.ts`, `src/app/api/metrics/route.ts`, `src/app/api/metrics/__tests__/metrics.test.ts`
- Modify: `next.config.js`, `package.json`

- [ ] **Step 1: Swap the import + call in the three routes**

In each of `integrate/route.ts`, `videos/route.ts`, `upload/route.ts`: replace `import { withMetrics } from '@/lib/metrics';` with `import { withEmf } from '@/lib/telemetry/emf';` and replace every `withMetrics(` call with `withEmf(` (same arguments — signature is identical).

- [ ] **Step 2: Delete the old telemetry files**

```bash
cd streaming-platform-upload
git rm src/lib/metrics.ts \
       src/app/api/metrics/route.ts \
       src/app/api/metrics/__tests__/metrics.test.ts \
       instrumentation.ts
```

- [ ] **Step 3: Remove instrumentationHook from next.config.js**

In `streaming-platform-upload/next.config.js`, delete the `instrumentationHook: true,` line (under `experimental`). If `experimental` is now empty, remove the empty `experimental: {}` key.

- [ ] **Step 4: Remove deps from package.json**

Remove these dependency lines from `streaming-platform-upload/package.json`:
```
"@opentelemetry/auto-instrumentations-node"
"@opentelemetry/exporter-metrics-otlp-grpc"
"@opentelemetry/exporter-trace-otlp-grpc"
"@opentelemetry/resources"
"@opentelemetry/sdk-node"
"@opentelemetry/semantic-conventions"
"prom-client"
```
Then run: `cd streaming-platform-upload && npm install` (updates `package-lock.json`).

- [ ] **Step 5: Verify no stragglers + full test + build**

Run:
```bash
cd streaming-platform-upload
grep -rn "withMetrics\|@/lib/metrics\|opentelemetry\|prom-client\|instrumentationHook" src instrumentation.ts next.config.js 2>/dev/null
npm test
npm run build
```
Expected: grep prints nothing; `npm test` PASS; build succeeds.

- [ ] **Step 6: Commit**

```bash
cd streaming-platform-upload
git add src/app/api/integrate/route.ts src/app/api/videos/route.ts src/app/api/upload/route.ts \
        next.config.js package.json package-lock.json
git commit -m "refactor(telemetry): swap /metrics+OTel for EMF wrapper, drop deps"
```

## TASK 10: Docs + CHANGELOG + vault sync (CLAUDE.md checklist)

**Files (per service repo):** `SPEC.md`, `CHANGELOG.md`, `docs/cloudwatch-emf-telemetry.md`; plus `obsidian-vault/services/<svc>/*`.

- [ ] **Step 1: For each of the four services, write `docs/cloudwatch-emf-telemetry.md`**

Content: motivation (serverless target → pull/scrape invalid; OTel push was dead weight), the EMF contract (paste the contract block from this plan's header), what was removed (OTel SDK, `/metrics`, deps), and the dev/prod data flow (Plan 2 wires LocalStack/CloudWatch).

- [ ] **Step 2: Prepend a `CHANGELOG.md` entry in each service**

```markdown
## [Unreleased] 2026-06-06
### Changed
- Telemetry now emits CloudWatch EMF to stdout (RED per request / per job).
### Removed
- OTel SDK push pipeline (internal/otel | instrumentation.ts) and the Prometheus
  `/metrics` endpoint + deps (fiberprometheus/otelfiber | prom-client/@opentelemetry).
```

- [ ] **Step 3: Update each `SPEC.md`** — replace any "exposes `/metrics`" / OTLP statements with the EMF contract.

- [ ] **Step 4: Sync `obsidian-vault/services/<svc>/`** spec pages to the EMF model (source of truth per CLAUDE.md).

- [ ] **Step 5: Commit (in each touched repo, and the vault repo separately)**

```bash
# example for one service:
cd streaming-ingest && git add SPEC.md CHANGELOG.md docs/cloudwatch-emf-telemetry.md && \
  git commit -m "docs(telemetry): document CloudWatch EMF migration"
# vault:
cd obsidian-vault && git add services && git commit -m "docs(telemetry): sync services to EMF model"
```

---

## Self-review

- **Spec coverage (decisions 4 & 5 of the design):** OTel SDK removal → Tasks 2,5,7. `/metrics` removal → Tasks 2,3,5,9. EMF replacement → Tasks 1,4,6,8 (impl) + 2,5,7,9 (wiring). Docs checklist → Task 10. Decisions 1,2,3,6,7 (CloudWatch prod, drop 7/8/9, LocalStack dev, archive telemetry) are **Plan 2** — out of scope here, noted in the header. ✓
- **Type/name consistency:** Go `Emitter{Service,Out,Now}` + `New(service)` + `.Middleware()` + `.Emit(route,method,status,latency)` used identically in Tasks 1/4; transcode `Emitter{Out,Now}` + `New()` + `.EmitJob(videoID,result,dur)` in Tasks 6/7. TS `emitEmf(input,sink)` + `withEmf(route,handler,sink)` in Tasks 8/9. ✓
- **Placeholder scan:** all code blocks are complete; Task 4 Step 3 and Task 5 Step 1 explicitly reference the verbatim Task 1 code (same module-agnostic file) rather than re-pasting the body — acceptable since the file is byte-identical and Task 1 is fully shown. ✓
- **Polyrepo:** every commit runs `cd <service>` first with repo-relative paths; no commits from the (non-git) monorepo root. ✓
