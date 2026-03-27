package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// runClaudeTeamsRelay implements `cmux claude-teams` on the remote side.
// It creates tmux shim scripts, sets up environment variables, gets the
// focused context via system.identify, and exec's into `claude`.
func runClaudeTeamsRelay(socketPath string, args []string, refreshAddr func() string) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createTmuxShimDir("claude-teams-bin", claudeTeamsShimScript)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux claude-teams: failed to create shim directory: %v\n", err)
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:         shimDir,
		socketPath:      socketPath,
		focused:         focused,
		tmuxPathPrefix:  "cmux-claude-teams",
		cmuxBinEnvVar:   "CMUX_CLAUDE_TEAMS_CMUX_BIN",
		termEnvVar:      "CMUX_CLAUDE_TEAMS_TERM",
		extraEnv: map[string]string{
			"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
		},
	})

	// Build launch arguments
	launchArgs := claudeTeamsLaunchArgs(args)

	// Find claude executable
	claudePath := findExecutable("claude", shimDir)

	if claudePath != "" {
		argv := append([]string{claudePath}, launchArgs...)
		err := syscall.Exec(claudePath, argv, os.Environ())
		fmt.Fprintf(os.Stderr, "cmux claude-teams: exec failed: %v\n", err)
		return 1
	}

	// Fallback: use PATH lookup
	claudePath, err = exec.LookPath("claude")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux claude-teams: claude not found in PATH\n")
		return 1
	}
	argv := append([]string{claudePath}, launchArgs...)
	execErr := syscall.Exec(claudePath, argv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux claude-teams: exec failed: %v\n", execErr)
	return 1
}

// runOMORelay implements `cmux omo` on the remote side.
func runOMORelay(socketPath string, args []string, refreshAddr func() string) int {
	rc := &rpcContext{socketPath: socketPath, refreshAddr: refreshAddr}

	shimDir, err := createOMOShimDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux omo: failed to create shim directory: %v\n", err)
		return 1
	}

	focused := getFocusedContext(rc)

	configureAgentEnvironment(agentConfig{
		shimDir:        shimDir,
		socketPath:     socketPath,
		focused:        focused,
		tmuxPathPrefix: "cmux-omo",
		cmuxBinEnvVar:  "CMUX_OMO_CMUX_BIN",
		termEnvVar:     "CMUX_OMO_TERM",
		extraEnv:       map[string]string{},
	})

	// Set OPENCODE_PORT if not already set
	if os.Getenv("OPENCODE_PORT") == "" {
		os.Setenv("OPENCODE_PORT", "4096")
	}

	// Build launch arguments
	launchArgs := args
	// Add --port if not already present
	hasPort := false
	for _, arg := range launchArgs {
		if arg == "--port" || strings.HasPrefix(arg, "--port=") {
			hasPort = true
			break
		}
	}
	if !hasPort {
		port := os.Getenv("OPENCODE_PORT")
		if port == "" {
			port = "4096"
		}
		launchArgs = append([]string{"--port", port}, launchArgs...)
	}

	opencodePath := findExecutable("opencode", shimDir)

	if opencodePath != "" {
		argv := append([]string{opencodePath}, launchArgs...)
		err := syscall.Exec(opencodePath, argv, os.Environ())
		fmt.Fprintf(os.Stderr, "cmux omo: exec failed: %v\n", err)
		return 1
	}

	opencodePath, err = exec.LookPath("opencode")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux omo: opencode not found in PATH\n")
		return 1
	}
	argv := append([]string{opencodePath}, launchArgs...)
	execErr := syscall.Exec(opencodePath, argv, os.Environ())
	fmt.Fprintf(os.Stderr, "cmux omo: exec failed: %v\n", execErr)
	return 1
}

// --- Shim creation ---

const claudeTeamsShimScript = `#!/usr/bin/env bash
set -euo pipefail
exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omoTmuxShimScript = `#!/usr/bin/env bash
set -euo pipefail
# Only match -V/-v as the first arg (top-level tmux flag).
# -v inside subcommands (e.g. split-window -v) is a vertical split flag.
case "${1:-}" in
  -V|-v) echo "tmux 3.4"; exit 0 ;;
esac
exec "${CMUX_OMO_CMUX_BIN:-cmux}" __tmux-compat "$@"
`

const omoNotifierShimScript = `#!/usr/bin/env bash
# Intercept terminal-notifier calls and route through cmux notify.
TITLE="" BODY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -title)   TITLE="$2"; shift 2 ;;
    -message) BODY="$2"; shift 2 ;;
    *)        shift ;;
  esac
done
exec "${CMUX_OMO_CMUX_BIN:-cmux}" notify --title "${TITLE:-OpenCode}" --body "${BODY:-}"
`

func createTmuxShimDir(dirName string, tmuxScript string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".cmuxterm", dirName)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	tmuxPath := filepath.Join(dir, "tmux")
	if err := writeShimIfChanged(tmuxPath, tmuxScript); err != nil {
		return "", err
	}
	return dir, nil
}

func createOMOShimDir() (string, error) {
	dir, err := createTmuxShimDir("omo-bin", omoTmuxShimScript)
	if err != nil {
		return "", err
	}
	notifierPath := filepath.Join(dir, "terminal-notifier")
	if err := writeShimIfChanged(notifierPath, omoNotifierShimScript); err != nil {
		return "", err
	}
	return dir, nil
}

func writeShimIfChanged(path string, content string) error {
	existing, err := os.ReadFile(path)
	if err == nil && string(existing) == content {
		return nil
	}
	if err := os.WriteFile(path, []byte(content), 0755); err != nil {
		return err
	}
	return nil
}

// --- Focused context ---

type focusedContext struct {
	workspaceId string
	windowId    string
	paneHandle  string
	surfaceId   string
}

func getFocusedContext(rc *rpcContext) *focusedContext {
	payload, err := rc.call("system.identify", nil)
	if err != nil {
		return nil
	}
	focused, _ := payload["focused"].(map[string]any)
	if focused == nil {
		return nil
	}

	wsId := stringFromAny(focused["workspace_id"], focused["workspace_ref"])
	paneId := stringFromAny(focused["pane_id"], focused["pane_ref"])
	if wsId == "" || paneId == "" {
		return nil
	}

	return &focusedContext{
		workspaceId: wsId,
		windowId:    stringFromAny(focused["window_id"], focused["window_ref"]),
		paneHandle:  strings.TrimSpace(paneId),
		surfaceId:   stringFromAny(focused["surface_id"], focused["surface_ref"]),
	}
}

func stringFromAny(values ...any) string {
	for _, v := range values {
		if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}

// --- Environment configuration ---

type agentConfig struct {
	shimDir        string
	socketPath     string
	focused        *focusedContext
	tmuxPathPrefix string
	cmuxBinEnvVar  string
	termEnvVar     string
	extraEnv       map[string]string
}

func configureAgentEnvironment(cfg agentConfig) {
	// Find our own executable path for the shim to call back
	selfPath, _ := os.Executable()
	if selfPath == "" {
		selfPath = "cmux"
	}
	os.Setenv(cfg.cmuxBinEnvVar, selfPath)

	// Prepend shim directory to PATH
	currentPath := os.Getenv("PATH")
	os.Setenv("PATH", cfg.shimDir+":"+currentPath)

	// Set fake TMUX/TMUX_PANE
	fakeTmux := fmt.Sprintf("/tmp/%s/default,0,0", cfg.tmuxPathPrefix)
	fakeTmuxPane := "%1"
	if cfg.focused != nil {
		windowToken := cfg.focused.windowId
		if windowToken == "" {
			windowToken = cfg.focused.workspaceId
		}
		fakeTmux = fmt.Sprintf("/tmp/%s/%s,%s,%s",
			cfg.tmuxPathPrefix, cfg.focused.workspaceId, windowToken, cfg.focused.paneHandle)
		fakeTmuxPane = "%" + cfg.focused.paneHandle
	}
	os.Setenv("TMUX", fakeTmux)
	os.Setenv("TMUX_PANE", fakeTmuxPane)

	// Terminal settings
	fakeTerm := os.Getenv(cfg.termEnvVar)
	if fakeTerm == "" {
		fakeTerm = "screen-256color"
	}
	os.Setenv("TERM", fakeTerm)

	// Socket path
	os.Setenv("CMUX_SOCKET_PATH", cfg.socketPath)
	os.Setenv("CMUX_SOCKET", cfg.socketPath)

	// Unset TERM_PROGRAM to prevent terminal detection conflicts
	os.Unsetenv("TERM_PROGRAM")

	// Set workspace/surface IDs from focused context
	if cfg.focused != nil {
		os.Setenv("CMUX_WORKSPACE_ID", cfg.focused.workspaceId)
		if cfg.focused.surfaceId != "" {
			os.Setenv("CMUX_SURFACE_ID", cfg.focused.surfaceId)
		}
	}

	// Extra environment variables
	for k, v := range cfg.extraEnv {
		os.Setenv(k, v)
	}
}

// --- Executable resolution ---

func findExecutable(name string, shimDir string) string {
	pathEnv := os.Getenv("PATH")
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" {
			continue
		}
		// Skip the shim directory itself
		if dir == shimDir {
			continue
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return candidate
		}
	}
	return ""
}

// --- Claude Teams launch args ---

func claudeTeamsLaunchArgs(args []string) []string {
	// Check if --teammate-mode is already specified
	for _, arg := range args {
		if arg == "--teammate-mode" || strings.HasPrefix(arg, "--teammate-mode=") {
			return args
		}
	}
	return append([]string{"--teammate-mode", "auto"}, args...)
}
