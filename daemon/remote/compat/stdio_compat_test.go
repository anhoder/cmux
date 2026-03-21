package compat

import (
	"encoding/base64"
	"testing"
)

func TestHelloFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", "testdata/hello.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", resp[0])
	}
	if got := resp[0]["result"].(map[string]any)["name"]; got != "cmuxd-remote" {
		t.Fatalf("hello name = %v, want cmuxd-remote", got)
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("ping should succeed: %+v", resp[1])
	}
}

func TestTerminalEchoFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", "testdata/terminal_echo.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", resp[0])
	}
	if got := decodeBase64Field(t, resp[1]["result"].(map[string]any), "data"); string(got) != "READY" {
		t.Fatalf("initial data = %q, want READY", string(got))
	}
	if ok, _ := resp[2]["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", resp[2])
	}
	if got := decodeBase64Field(t, resp[3]["result"].(map[string]any), "data"); string(got) != "hello\r\n" {
		t.Fatalf("echo data = %q, want %q", string(got), "hello\r\n")
	}
}

func TestSessionLifecycleFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", "testdata/session_lifecycle.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("session.open should succeed: %+v", resp[0])
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", resp[1])
	}
	statusResult, ok := resp[2]["result"].(map[string]any)
	if !ok {
		t.Fatalf("session.status result missing: %+v", resp[2])
	}
	if got := int(statusResult["effective_cols"].(float64)); got != 120 {
		t.Fatalf("effective_cols = %d, want 120", got)
	}
	if got := int(statusResult["effective_rows"].(float64)); got != 40 {
		t.Fatalf("effective_rows = %d, want 40", got)
	}
	if ok, _ := resp[3]["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", resp[3])
	}
}

func decodeBase64Field(t *testing.T, payload map[string]any, key string) []byte {
	t.Helper()

	encoded, _ := payload[key].(string)
	if encoded == "" {
		t.Fatalf("missing %s field in %+v", key, payload)
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode %s: %v", key, err)
	}
	return data
}
