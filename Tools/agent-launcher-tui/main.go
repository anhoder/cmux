package main

import (
	"bytes"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type config struct {
	cmuxPath    string
	socketPath  string
	password    string
	basePath    string
	name        string
	prompt      string
	placement   string
	imagePaths  []string
	jsonOutput  bool
	useAIName   bool
	claudeCount int
	codexCount  int
	openCount   int
}

type stringList []string

type imageAttachment struct {
	Token string
	Path  string
	Name  string
}

type focusMode int

const (
	focusPrompt focusMode = iota
	focusConfig
)

type model struct {
	cfg            config
	textarea       textarea.Model
	width          int
	height         int
	focus          focusMode
	selectedConfig int
	images         []imageAttachment
	status         string
	statusKind     string
	launching      bool
}

type placementOption struct {
	value string
	label string
	help  string
}

type launchDoneMsg struct {
	output string
	err    error
}

type tokenRange struct {
	rawStart int
	rawEnd   int
	value    string
}

var imageTokenRE = regexp.MustCompile(`\[Image #[0-9]+\]`)

var imageExtensions = map[string]bool{
	".avif": true,
	".bmp":  true,
	".gif":  true,
	".heic": true,
	".heif": true,
	".jpeg": true,
	".jpg":  true,
	".png":  true,
	".tif":  true,
	".tiff": true,
	".webp": true,
}

var placementOptions = []placementOption{
	{value: "splits", label: "Splits", help: "one workspace, split panes"},
	{value: "tabs", label: "Tabs", help: "one workspace, surface tabs"},
	{value: "workspaces", label: "Workspaces", help: "one workspace per agent"},
}

var (
	blue      = lipgloss.Color("#7AA7FF")
	text      = lipgloss.Color("#D7DCE5")
	muted     = lipgloss.Color("#8B93A3")
	dim       = lipgloss.Color("#5D6572")
	red       = lipgloss.Color("#F87171")
	screenBG  = lipgloss.Color("#090B10")
	inputBG   = lipgloss.Color("#20242C")
	configBG  = lipgloss.Color("#11151D")
	rowBG     = lipgloss.Color("#1A2130")
	subtle    = lipgloss.NewStyle().Foreground(muted)
	dimText   = lipgloss.NewStyle().Foreground(dim)
	hot       = lipgloss.NewStyle().Foreground(blue)
	errorText = lipgloss.NewStyle().Foreground(red)
	selected  = lipgloss.NewStyle().Foreground(text).Background(rowBG)
)

func main() {
	cfg := parseConfig()
	m := initialModel(cfg)
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "cmux-agent-launcher-tui: %v\n", err)
		os.Exit(1)
	}
}

func parseConfig() config {
	cfg := config{
		cmuxPath:    "cmux",
		placement:   "splits",
		useAIName:   true,
		claudeCount: 1,
		codexCount:  1,
		openCount:   0,
	}
	var imagePaths stringList
	flag.StringVar(&cfg.cmuxPath, "cmux", cfg.cmuxPath, "cmux executable path")
	flag.StringVar(&cfg.socketPath, "socket", "", "cmux socket path")
	flag.StringVar(&cfg.password, "password", "", "cmux socket password")
	flag.StringVar(&cfg.basePath, "base", "", "repo or hq path")
	flag.StringVar(&cfg.name, "name", "", "workspace name")
	flag.StringVar(&cfg.prompt, "prompt", "", "initial prompt")
	flag.StringVar(&cfg.placement, "placement", cfg.placement, "splits, tabs, or workspaces")
	flag.Var(&imagePaths, "image", "initial image path")
	flag.IntVar(&cfg.claudeCount, "claude", cfg.claudeCount, "Claude pane count")
	flag.IntVar(&cfg.codexCount, "codex", cfg.codexCount, "Codex pane count")
	flag.IntVar(&cfg.openCount, "opencode", cfg.openCount, "OpenCode pane count")
	flag.BoolVar(&cfg.jsonOutput, "json", false, "request JSON backend output")
	noAIName := flag.Bool("no-ai-name", false, "disable AI workspace name generation")
	flag.Parse()
	cfg.useAIName = !*noAIName
	cfg.claudeCount = clampInt(cfg.claudeCount, 0, 8)
	cfg.codexCount = clampInt(cfg.codexCount, 0, 8)
	cfg.openCount = clampInt(cfg.openCount, 0, 8)
	cfg.placement = normalizePlacement(cfg.placement)
	cfg.imagePaths = append([]string(nil), imagePaths...)
	return cfg
}

func (l *stringList) String() string {
	if l == nil {
		return ""
	}
	return strings.Join(*l, ",")
}

func (l *stringList) Set(value string) error {
	*l = append(*l, value)
	return nil
}

func initialModel(cfg config) model {
	ta := textarea.New()
	ta.Placeholder = "What should the agents work on?"
	ta.Prompt = "  "
	ta.ShowLineNumbers = false
	ta.CharLimit = 20000
	ta.SetWidth(68)
	ta.SetHeight(8)
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle()
	ta.FocusedStyle.Prompt = lipgloss.NewStyle().Foreground(blue).Background(inputBG)
	ta.FocusedStyle.Text = lipgloss.NewStyle().Foreground(text).Background(inputBG)
	ta.FocusedStyle.Placeholder = lipgloss.NewStyle().Foreground(dim).Background(inputBG)
	ta.FocusedStyle.Base = lipgloss.NewStyle().Foreground(text).Background(inputBG)
	ta.BlurredStyle = ta.FocusedStyle
	ta.Focus()

	m := model{
		cfg:      cfg,
		textarea: ta,
		status:   "ready",
	}
	if strings.TrimSpace(cfg.prompt) != "" {
		m.textarea.SetValue(cfg.prompt)
	}
	for _, rawPath := range cfg.imagePaths {
		path, ok := normalizeImagePath(rawPath)
		if !ok {
			continue
		}
		token := m.imageTokenForPath(path)
		if !strings.Contains(m.textarea.Value(), token) {
			if strings.TrimSpace(m.textarea.Value()) != "" {
				m.textarea.InsertString(" ")
			}
			m.textarea.InsertString(token)
		}
	}
	return m
}

func (m model) Init() tea.Cmd {
	return textarea.Blink
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.resize(msg.Width, msg.Height)
		return m, nil
	case launchDoneMsg:
		m.launching = false
		if msg.err != nil {
			m.statusKind = "error"
			m.status = strings.TrimSpace(msg.output)
			if m.status == "" {
				m.status = msg.err.Error()
			}
			return m, nil
		}
		m.statusKind = "ok"
		m.status = firstNonEmptyLine(msg.output)
		if m.status == "" {
			m.status = "workspace created"
		}
		m.textarea.Reset()
		m.images = nil
		return m, nil
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "ctrl+r":
			return m.startLaunch()
		case "tab":
			m.toggleFocus()
			return m, nil
		}

		if m.launching {
			return m, nil
		}

		if m.focus == focusConfig {
			switch msg.String() {
			case "up", "k":
				m.moveSelectedConfig(-1)
			case "down", "j":
				m.moveSelectedConfig(1)
			case "left", "h", "-":
				m.adjustSelectedConfig(-1)
			case "right", "l", "+", "=":
				m.adjustSelectedConfig(1)
			case " ":
				m.chooseSelectedPlacement()
			case "enter", "esc":
				m.focus = focusPrompt
				cmd = m.textarea.Focus()
			}
			return m, cmd
		}

		if msg.Type == tea.KeyRunes && len(msg.Runes) > 0 {
			replacement, changed := m.replaceImagePaths(string(msg.Runes))
			if changed {
				m.textarea.InsertString(replacement)
				m.normalizeImageTokenCursor("right")
				m.statusKind = "ok"
				m.status = fmt.Sprintf("attached %d image%s", len(m.images), plural(len(m.images)))
				return m, nil
			}
		}
		m.textarea, cmd = m.textarea.Update(msg)
		switch msg.String() {
		case "left", "ctrl+b", "alt+left":
			m.normalizeImageTokenCursor("left")
		case "right", "ctrl+f", "alt+right":
			m.normalizeImageTokenCursor("right")
		}
		return m, cmd
	}

	m.textarea, cmd = m.textarea.Update(msg)
	return m, cmd
}

func (m *model) resize(width, height int) {
	m.width = width
	m.height = height
	boxWidth := clampInt(width-8, 68, 104)
	textWidth := clampInt(boxWidth-12, 50, 88)
	textHeight := clampInt(height/5, 5, 8)
	m.textarea.SetWidth(textWidth)
	m.textarea.SetHeight(textHeight)
}

func (m *model) toggleFocus() {
	if m.focus == focusPrompt {
		m.focus = focusConfig
		m.textarea.Blur()
		return
	}
	m.focus = focusPrompt
	m.textarea.Focus()
}

func (m *model) moveSelectedConfig(delta int) {
	count := 3 + len(placementOptions)
	m.selectedConfig = (m.selectedConfig + delta + count) % count
}

func (m *model) adjustSelectedConfig(delta int) {
	switch m.selectedConfig {
	case 0:
		m.cfg.claudeCount = clampInt(m.cfg.claudeCount+delta, 0, 8)
	case 1:
		m.cfg.codexCount = clampInt(m.cfg.codexCount+delta, 0, 8)
	case 2:
		m.cfg.openCount = clampInt(m.cfg.openCount+delta, 0, 8)
	default:
		index := placementIndex(m.cfg.placement)
		index = (index + delta + len(placementOptions)) % len(placementOptions)
		m.cfg.placement = placementOptions[index].value
		m.selectedConfig = 3 + index
	}
}

func (m *model) chooseSelectedPlacement() {
	index := m.selectedConfig - 3
	if index >= 0 && index < len(placementOptions) {
		m.cfg.placement = placementOptions[index].value
	}
}

func (m model) startLaunch() (tea.Model, tea.Cmd) {
	prompt := strings.TrimSpace(m.textarea.Value())
	if prompt == "" && len(m.images) == 0 {
		m.statusKind = "error"
		m.status = "write a prompt or attach an image first"
		return m, nil
	}
	if m.cfg.claudeCount+m.cfg.codexCount+m.cfg.openCount == 0 {
		m.cfg.claudeCount = 1
		m.cfg.codexCount = 1
	}
	m.launching = true
	m.statusKind = ""
	m.status = "creating worktrees and cmux layout..."
	cfg := m.cfg
	images := append([]imageAttachment(nil), m.images...)
	return m, func() tea.Msg {
		args := []string{}
		if cfg.socketPath != "" {
			args = append(args, "--socket", cfg.socketPath)
		}
		if cfg.password != "" {
			args = append(args, "--password", cfg.password)
		}
		if cfg.jsonOutput {
			args = append(args, "--json")
		}
		args = append(args,
			"agent-launcher", "run",
			"--prompt", prompt,
			"--claude", strconv.Itoa(cfg.claudeCount),
			"--codex", strconv.Itoa(cfg.codexCount),
			"--opencode", strconv.Itoa(cfg.openCount),
			"--placement", cfg.placement,
		)
		if cfg.basePath != "" {
			args = append(args, "--base", cfg.basePath)
		}
		if cfg.name != "" {
			args = append(args, "--name", cfg.name)
		}
		if !cfg.useAIName {
			args = append(args, "--no-ai-name")
		}
		for _, image := range images {
			args = append(args, "--image", image.Path)
		}
		cmd := exec.Command(cfg.cmuxPath, args...)
		var output bytes.Buffer
		cmd.Stdout = &output
		cmd.Stderr = &output
		err := cmd.Run()
		return launchDoneMsg{output: output.String(), err: err}
	}
}

func (m model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	boxWidth := clampInt(m.width-8, 68, 104)
	promptWidth := clampInt(boxWidth-10, 54, 90)
	label := subtle.Width(promptWidth + 4).Align(lipgloss.Left).Render("cmux agent launcher")
	if m.focus == focusPrompt {
		label = hot.Width(promptWidth + 4).Align(lipgloss.Left).Render("cmux agent launcher")
	}
	inputBox := lipgloss.NewStyle().
		Width(promptWidth+4).
		Background(inputBG).
		Padding(1, 2).
		Render(m.textarea.View())
	config := m.configPanel(promptWidth + 4)
	images := m.imageLine(promptWidth + 4)
	status := m.statusLine(promptWidth + 4)
	help := dimText.Width(promptWidth + 4).Align(lipgloss.Center).Render("ctrl+r launch   tab config   arrows adjust   space choose   ctrl+c quit")

	body := lipgloss.JoinVertical(
		lipgloss.Center,
		label,
		inputBox,
		"",
		config,
		"",
		images,
		status,
		help,
	)
	rendered := lipgloss.NewStyle().
		Foreground(text).
		Background(screenBG).
		Render(body)
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, rendered)
}

func (m model) sectionTitle(label string, active bool, width int) string {
	style := subtle
	if active {
		style = hot
	}
	return style.Width(width).Align(lipgloss.Left).Render(label)
}

func (m model) configPanel(width int) string {
	lines := []string{
		m.sectionTitle("Agents", m.focus == focusConfig && m.selectedConfig < 3, width),
		m.agentRow(0, "Claude Code", m.cfg.claudeCount),
		m.agentRow(1, "Codex", m.cfg.codexCount),
		m.agentRow(2, "OpenCode Kimi", m.cfg.openCount),
		"",
		m.sectionTitle("Placement", m.focus == focusConfig && m.selectedConfig >= 3, width),
	}
	for index, option := range placementOptions {
		lines = append(lines, m.placementRow(index, option))
	}
	return lipgloss.NewStyle().
		Width(width).
		Background(configBG).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) agentRow(index int, label string, count int) string {
	active := m.focus == focusConfig && m.selectedConfig == index
	prefix := " "
	if active {
		prefix = ">"
	}
	line := fmt.Sprintf("%s %-18s  [-] %d [+]", prefix, label, count)
	if active {
		return selected.Render(line)
	}
	return subtle.Render(line)
}

func (m model) placementRow(index int, option placementOption) string {
	rowIndex := index + 3
	active := m.focus == focusConfig && m.selectedConfig == rowIndex
	chosen := m.cfg.placement == option.value
	prefix := " "
	if active {
		prefix = ">"
	}
	mark := "( )"
	if chosen {
		mark = "(*)"
	}
	line := fmt.Sprintf("%s %s %-11s %s", prefix, mark, option.label, option.help)
	if active {
		return selected.Render(line)
	}
	if chosen {
		return hot.Render(line)
	}
	return subtle.Render(line)
}

func (m model) imageLine(width int) string {
	if len(m.images) == 0 {
		return subtle.Width(width).Align(lipgloss.Center).Render("Images: drop or paste a file")
	}
	parts := make([]string, 0, len(m.images))
	for _, image := range m.images {
		parts = append(parts, hot.Render(image.Token)+" "+subtle.Render(image.Name))
	}
	return lipgloss.NewStyle().Width(width).Align(lipgloss.Center).Render("Images: " + strings.Join(parts, "  "))
}

func (m model) statusLine(width int) string {
	text := m.status
	if m.launching {
		text = "creating worktrees and cmux layout..."
	}
	style := subtle
	if m.statusKind == "error" {
		style = errorText
	} else if m.statusKind == "ok" || m.launching {
		style = hot
	}
	if strings.TrimSpace(text) == "" {
		text = "ready"
	}
	return style.Width(width).Align(lipgloss.Center).Render(text)
}

func (m *model) replaceImagePaths(input string) (string, bool) {
	tokens := shellTokens(input)
	if len(tokens) == 0 {
		return input, false
	}

	type replacement struct {
		start int
		end   int
		token string
	}
	var replacements []replacement
	for _, token := range tokens {
		path, ok := normalizeImagePath(token.value)
		if !ok {
			continue
		}
		replacements = append(replacements, replacement{
			start: token.rawStart,
			end:   token.rawEnd,
			token: m.imageTokenForPath(path),
		})
	}
	if len(replacements) == 0 {
		return input, false
	}

	var out strings.Builder
	last := 0
	for _, repl := range replacements {
		if repl.start < last {
			continue
		}
		out.WriteString(input[last:repl.start])
		out.WriteString(repl.token)
		last = repl.end
	}
	out.WriteString(input[last:])
	return out.String(), true
}

func (m *model) imageTokenForPath(path string) string {
	for _, image := range m.images {
		if image.Path == path {
			return image.Token
		}
	}
	token := fmt.Sprintf("[Image #%d]", len(m.images)+1)
	m.images = append(m.images, imageAttachment{
		Token: token,
		Path:  path,
		Name:  filepath.Base(path),
	})
	return token
}

func (m *model) normalizeImageTokenCursor(direction string) {
	lines := strings.Split(m.textarea.Value(), "\n")
	lineIndex := m.textarea.Line()
	if lineIndex < 0 || lineIndex >= len(lines) {
		return
	}
	line := lines[lineIndex]
	info := m.textarea.LineInfo()
	col := info.StartColumn + info.CharOffset
	for _, loc := range imageTokenRE.FindAllStringIndex(line, -1) {
		start := runeIndexAtByte(line, loc[0])
		end := runeIndexAtByte(line, loc[1])
		if col > start && col < end {
			if direction == "left" {
				m.textarea.SetCursor(start)
			} else {
				m.textarea.SetCursor(end)
			}
			return
		}
	}
}

func shellTokens(input string) []tokenRange {
	var tokens []tokenRange
	var current strings.Builder
	inToken := false
	start := 0
	quote := rune(0)
	escaping := false

	flush := func(end int) {
		if !inToken {
			return
		}
		tokens = append(tokens, tokenRange{
			rawStart: start,
			rawEnd:   end,
			value:    current.String(),
		})
		current.Reset()
		inToken = false
		quote = 0
		escaping = false
	}

	for i, r := range input {
		if !inToken && !unicode.IsSpace(r) {
			inToken = true
			start = i
		}
		if !inToken {
			continue
		}
		if escaping {
			current.WriteRune(r)
			escaping = false
			continue
		}
		if r == '\\' {
			escaping = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				current.WriteRune(r)
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			continue
		}
		if unicode.IsSpace(r) {
			flush(i)
			continue
		}
		current.WriteRune(r)
	}
	flush(len(input))
	return tokens
}

func normalizeImagePath(raw string) (string, bool) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", false
	}
	if strings.HasPrefix(value, "file://") {
		parsed, err := url.Parse(value)
		if err != nil || !parsed.IsAbs() {
			return "", false
		}
		value = parsed.Path
	}
	if strings.HasPrefix(value, "~") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false
		}
		if value == "~" {
			value = home
		} else if strings.HasPrefix(value, "~/") {
			value = filepath.Join(home, value[2:])
		}
	}
	if !filepath.IsAbs(value) {
		abs, err := filepath.Abs(value)
		if err != nil {
			return "", false
		}
		value = abs
	}
	ext := strings.ToLower(filepath.Ext(value))
	if !imageExtensions[ext] {
		return "", false
	}
	info, err := os.Stat(value)
	if err != nil || info.IsDir() {
		return "", false
	}
	clean, err := filepath.EvalSymlinks(value)
	if err == nil {
		value = clean
	}
	return filepath.Clean(value), true
}

func runeIndexAtByte(s string, byteIndex int) int {
	if byteIndex <= 0 {
		return 0
	}
	if byteIndex >= len(s) {
		return utf8.RuneCountInString(s)
	}
	return utf8.RuneCountInString(s[:byteIndex])
}

func firstNonEmptyLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

func plural(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}

func clampInt(value, minValue, maxValue int) int {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func normalizePlacement(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "tab", "tabs":
		return "tabs"
	case "workspace", "workspaces", "separate":
		return "workspaces"
	default:
		return "splits"
	}
}

func placementIndex(value string) int {
	normalized := normalizePlacement(value)
	for index, option := range placementOptions {
		if option.value == normalized {
			return index
		}
	}
	return 0
}
