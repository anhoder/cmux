package compat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

var (
	buildOnce       sync.Once
	builtBinaryPath string
	buildBinaryErr  error
)

func daemonBinary(t *testing.T) string {
	t.Helper()

	if override := os.Getenv("CMUX_REMOTE_DAEMON_BIN"); override != "" {
		return override
	}

	buildOnce.Do(func() {
		outputDir, err := os.MkdirTemp("", "cmuxd-remote-go-*")
		if err != nil {
			buildBinaryErr = err
			return
		}
		builtBinaryPath = filepath.Join(outputDir, "cmuxd-remote-go")

		cmd := exec.Command("go", "build", "-ldflags", "-linkmode=external", "-o", builtBinaryPath, "./cmd/cmuxd-remote")
		cmd.Dir = daemonRemoteRoot()
		output, err := cmd.CombinedOutput()
		if err != nil {
			buildBinaryErr = fmt.Errorf("go build failed: %w\n%s", err, strings.TrimSpace(string(output)))
			return
		}
	})

	if buildBinaryErr != nil {
		t.Fatalf("build daemon binary: %v", buildBinaryErr)
	}
	return builtBinaryPath
}

func runJSONLFixture(t *testing.T, bin string, args ...string) []map[string]any {
	t.Helper()

	if len(args) == 0 {
		t.Fatal("runJSONLFixture requires daemon args and a fixture path")
	}
	fixturePath := args[len(args)-1]
	daemonArgs := args[:len(args)-1]

	cmd := exec.Command(bin, daemonArgs...)
	cmd.Dir = daemonRemoteRoot()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start daemon: %v", err)
	}

	reader := bufio.NewReader(stdout)
	vars := map[string]string{}
	var responses []map[string]any

	for _, rawLine := range readFixtureLines(t, fixturePath) {
		line := substitutePlaceholders(t, rawLine, vars)
		if _, err := io.WriteString(stdin, line+"\n"); err != nil {
			t.Fatalf("write request %q: %v", line, err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response for %q: %v\nstderr:\n%s", line, err, stderr.String())
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response %q: %v", strings.TrimSpace(respLine), err)
		}
		captureResponseVars(payload, vars)
		responses = append(responses, payload)
	}

	if err := stdin.Close(); err != nil {
		t.Fatalf("close stdin: %v", err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("daemon exited with error: %v\nstderr:\n%s", err, stderr.String())
	}

	return responses
}

func readFixtureLines(t *testing.T, fixturePath string) []string {
	t.Helper()

	data, err := os.ReadFile(filepath.Join(compatPackageDir(), fixturePath))
	if err != nil {
		t.Fatalf("read fixture %q: %v", fixturePath, err)
	}

	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		lines = append(lines, trimmed)
	}
	return lines
}

func substitutePlaceholders(t *testing.T, input string, vars map[string]string) string {
	t.Helper()

	output := input
	for {
		start := strings.Index(output, "{{")
		if start == -1 {
			return output
		}
		end := strings.Index(output[start+2:], "}}")
		if end == -1 {
			t.Fatalf("unterminated placeholder in %q", input)
		}

		key := output[start+2 : start+2+end]
		value, ok := vars[key]
		if !ok {
			t.Fatalf("missing placeholder %q for fixture line %q", key, input)
		}
		output = output[:start] + value + output[start+2+end+2:]
	}
}

func captureResponseVars(payload map[string]any, vars map[string]string) {
	result, _ := payload["result"].(map[string]any)
	if result == nil {
		return
	}

	for _, key := range []string{"session_id", "attachment_id", "stream_id"} {
		if value, ok := result[key].(string); ok && value != "" {
			vars[key] = value
		}
	}
	if value, ok := result["offset"].(float64); ok {
		vars["offset"] = fmt.Sprintf("%.0f", value)
	}
}

func daemonRemoteRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

func compatPackageDir() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(file)
}
