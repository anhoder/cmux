import type * as monaco from "monaco-editor";

export const CMUX_THEME_DARK = "cmux-dark";
export const CMUX_THEME_LIGHT = "cmux-light";

export function registerCmuxThemes(monacoNs: typeof monaco): void {
  monacoNs.editor.defineTheme(CMUX_THEME_DARK, {
    base: "vs-dark",
    inherit: true,
    rules: [],
    colors: {},
  });
  monacoNs.editor.defineTheme(CMUX_THEME_LIGHT, {
    base: "vs",
    inherit: true,
    rules: [],
    colors: {},
  });
}

export interface CmuxPalette {
  isDark: boolean;
  backgroundHex: string;
  foregroundHex: string;
  cursorHex?: string;
  selectionBackgroundHex?: string;
  /** ANSI 0..15, lowercase `#rrggbb`. Optional. */
  ansi?: string[];
}

/** Apply a Ghostty-derived palette to our Monaco theme and activate it. */
export function applyCmuxPalette(
  monacoNs: typeof monaco,
  palette: CmuxPalette,
): void {
  const base = palette.isDark ? "vs-dark" : "vs";
  const name = palette.isDark ? CMUX_THEME_DARK : CMUX_THEME_LIGHT;
  const ansi = palette.ansi ?? [];

  const rules = ansiTokenRules(ansi);
  const colors = editorColors(palette);

  monacoNs.editor.defineTheme(name, {
    base,
    inherit: true,
    rules,
    colors,
  });
  monacoNs.editor.setTheme(name);

  // Mirror into CSS so the host never flashes white-on-white when Monaco
  // remounts or during style recomputation.
  document.documentElement.style.setProperty(
    "--cmux-editor-bg",
    palette.backgroundHex,
  );
  document.documentElement.style.setProperty(
    "--cmux-editor-fg",
    palette.foregroundHex,
  );
  document.body.style.background = palette.backgroundHex;
  document.body.style.color = palette.foregroundHex;
  document.documentElement.style.colorScheme = palette.isDark
    ? "dark"
    : "light";
}

function editorColors(
  palette: CmuxPalette,
): { [key: string]: string } {
  const cursor = palette.cursorHex ?? palette.foregroundHex;
  const selection = palette.selectionBackgroundHex
    ?? (palette.isDark ? "#264f7866" : "#add6ff66");
  const ansi = palette.ansi ?? [];

  return {
    "editor.background": palette.backgroundHex,
    "editor.foreground": palette.foregroundHex,
    "editorCursor.foreground": cursor,
    "editor.lineHighlightBackground": palette.isDark ? "#ffffff0a" : "#0000000a",
    "editor.selectionBackground": selection,
    "editor.inactiveSelectionBackground": palette.isDark
      ? "#3a3d4166"
      : "#e5ebf1",
    "editorGutter.background": palette.backgroundHex,
    "editorLineNumber.foreground": palette.isDark ? "#6e7681" : "#b1b1b3",
    "editorLineNumber.activeForeground": palette.foregroundHex,
    "editorWidget.background": palette.backgroundHex,
    "editorSuggestWidget.background": palette.backgroundHex,
    "editor.findMatchBackground": ansi[3] ? withAlpha(ansi[3], 0x66) : "#665500",
    "editor.findMatchHighlightBackground": ansi[3]
      ? withAlpha(ansi[3], 0x33)
      : "#ea5c0055",
    "terminal.background": palette.backgroundHex,
    "terminal.foreground": palette.foregroundHex,
    "terminalCursor.foreground": cursor,
    ...ansiEditorColors(ansi),
  };
}

function ansiEditorColors(ansi: string[]): { [key: string]: string } {
  const out: { [key: string]: string } = {};
  const keys: Array<[number, string]> = [
    [0, "terminal.ansiBlack"],
    [1, "terminal.ansiRed"],
    [2, "terminal.ansiGreen"],
    [3, "terminal.ansiYellow"],
    [4, "terminal.ansiBlue"],
    [5, "terminal.ansiMagenta"],
    [6, "terminal.ansiCyan"],
    [7, "terminal.ansiWhite"],
    [8, "terminal.ansiBrightBlack"],
    [9, "terminal.ansiBrightRed"],
    [10, "terminal.ansiBrightGreen"],
    [11, "terminal.ansiBrightYellow"],
    [12, "terminal.ansiBrightBlue"],
    [13, "terminal.ansiBrightMagenta"],
    [14, "terminal.ansiBrightCyan"],
    [15, "terminal.ansiBrightWhite"],
  ];
  for (const [idx, key] of keys) {
    const value = ansi[idx];
    if (value) out[key] = value;
  }
  return out;
}

/** Map Monaco token categories to Ghostty ANSI colors. */
function ansiTokenRules(
  ansi: string[],
): Array<{ token: string; foreground?: string; fontStyle?: string }> {
  if (ansi.length < 16) return [];

  const stripHash = (hex: string) => hex.replace(/^#/, "").toLowerCase();
  const red = stripHash(ansi[1]!);
  const green = stripHash(ansi[2]!);
  const yellow = stripHash(ansi[3]!);
  const blue = stripHash(ansi[4]!);
  const magenta = stripHash(ansi[5]!);
  const cyan = stripHash(ansi[6]!);
  const brightBlack = stripHash(ansi[8]!);

  return [
    { token: "", foreground: "" }, // keeps inherit

    { token: "comment", foreground: brightBlack, fontStyle: "italic" },
    { token: "comment.doc", foreground: brightBlack, fontStyle: "italic" },

    { token: "string", foreground: green },
    { token: "string.escape", foreground: cyan },
    { token: "string.regexp", foreground: magenta },

    { token: "number", foreground: magenta },
    { token: "number.hex", foreground: magenta },
    { token: "number.octal", foreground: magenta },
    { token: "number.float", foreground: magenta },

    { token: "keyword", foreground: blue, fontStyle: "bold" },
    { token: "keyword.control", foreground: blue, fontStyle: "bold" },
    { token: "keyword.operator", foreground: cyan },
    { token: "keyword.other", foreground: blue },

    { token: "type", foreground: yellow },
    { token: "type.identifier", foreground: yellow },

    { token: "identifier", foreground: "" },
    { token: "variable", foreground: "" },
    { token: "variable.parameter", foreground: red },

    { token: "function", foreground: cyan },
    { token: "function.name", foreground: cyan },
    { token: "support.function", foreground: cyan },

    { token: "constant", foreground: magenta },
    { token: "constant.language", foreground: magenta },

    { token: "tag", foreground: red },
    { token: "tag.id", foreground: red },
    { token: "attribute.name", foreground: yellow },
    { token: "attribute.value", foreground: green },

    { token: "delimiter", foreground: stripHash(ansi[7]!) },
    { token: "operator", foreground: cyan },

    { token: "invalid", foreground: red, fontStyle: "bold" },
  ];
}

/** Apply a hex alpha byte to a `#rrggbb` color. Returns `#rrggbbaa`. */
function withAlpha(hexColor: string, alphaByte: number): string {
  const clean = hexColor.replace(/^#/, "");
  if (clean.length !== 6) return hexColor;
  const a = Math.max(0, Math.min(255, alphaByte))
    .toString(16)
    .padStart(2, "0");
  return `#${clean}${a}`;
}
