import { test, expect } from "bun:test";
import {
  cls, flatten, posToIdx, idxToPos, wordFwd, wordBack, wordEnd, searchFrom,
  firstNonBlank, selectionText, prefixCommand, findChar, CopyMode,
} from "./copymode.ts";

test("approved intra-word symbols: - is part of a word, . is not", () => {
  expect(cls("-")).toBe("word");
  expect(cls("_")).toBe("word");
  expect(cls(".")).toBe("punct");
  expect(wordFwd("--kebab-flag x", 0)).toBe(13);   // whole flag is one word -> 'x'
  expect(wordFwd("a.b c", 0)).toBe(1);             // '.' still splits -> the '.'
});

test("WORD motions (big=true) treat punctuation as part of the word", () => {
  const t = "foo.bar baz";
  expect(wordFwd(t, 0)).toBe(3);          // w -> the '.'
  expect(wordFwd(t, 0, true)).toBe(8);    // W -> 'baz' (foo.bar is one WORD)
  expect(wordBack(t, 8, true)).toBe(0);   // B -> start of foo.bar
  expect(wordEnd(t, 0, true)).toBe(6);    // E -> 'r' of foo.bar
});

test("findChar: f/F and t/T (till)", () => {
  const t = "foo.bar baz";
  expect(findChar(t, 0, "b", 1, false)).toBe(4);   // f b
  expect(findChar(t, 0, "b", 1, true)).toBe(3);    // t b (one before)
  expect(findChar(t, 10, "f", -1, false)).toBe(0); // F f (backward)
  expect(findChar(t, 0, "z", -1, false)).toBe(0);  // not found -> stays
});

test("tmux prefix (Ctrl+a) command table", () => {
  expect(prefixCommand("[")).toBe("copy");   // ^a [ -> copy/select mode
  expect(prefixCommand("]")).toBe("paste");  // ^a ] -> paste buffer
  expect(prefixCommand("?")).toBe("help");
  expect(prefixCommand("x")).toBeNull();
  expect(prefixCommand("Escape")).toBeNull();
});

const lines = ["foo bar  baz", "  hello world", "qux"];
const { text, rowStart } = flatten(lines);

test("cls classifies characters", () => {
  expect(cls("a")).toBe("word");
  expect(cls("_")).toBe("word");
  expect(cls(" ")).toBe("blank");
  expect(cls(".")).toBe("punct");
  expect(cls(undefined)).toBe("blank");
});

test("flatten + pos/idx round-trip", () => {
  expect(rowStart).toEqual([0, 13, 27]);
  expect(text.length).toBe(30);
  for (const p of [{ r: 0, c: 0 }, { r: 1, c: 8 }, { r: 2, c: 2 }]) {
    expect(idxToPos(lines, rowStart, posToIdx(rowStart, p))).toEqual(p);
  }
});

test("word motions (w/b/e), including across line boundaries", () => {
  expect(wordFwd(text, 0)).toBe(4);   // foo -> bar
  expect(wordFwd(text, 4)).toBe(9);   // bar -> baz (skips 2 spaces)
  expect(wordFwd(text, 9)).toBe(15);  // baz -> hello (next line)
  expect(wordBack(text, 15)).toBe(9); // hello -> baz
  expect(wordEnd(text, 0)).toBe(2);   // -> end of foo
});

test("search is case-insensitive and wraps", () => {
  expect(idxToPos(lines, rowStart, searchFrom(text, 0, "WORLD", 1))).toEqual({ r: 1, c: 8 });
  // from end, forward search wraps back to an earlier match
  expect(searchFrom(text, text.length - 1, "foo", 1)).toBe(0);
});

test("firstNonBlank", () => {
  expect(firstNonBlank("  hello")).toBe(2);
  expect(firstNonBlank("x")).toBe(0);
});

test("selectionText charwise and linewise (order-independent)", () => {
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 0, c: 2 }, false)).toBe("foo");
  expect(selectionText(lines, { r: 0, c: 2 }, { r: 0, c: 0 }, false)).toBe("foo"); // reversed
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 1, c: 4 }, false)).toBe("foo bar  baz\n  hel");
  expect(selectionText(lines, { r: 0, c: 0 }, { r: 1, c: 0 }, true)).toBe("foo bar  baz\n  hello world");
});

// ---- controller state machine (minimal fake DOM) --------------------------
function fakeEl(props: any = {}): any {
  return {
    innerText: props.innerText || "", innerHTML: "", className: "", textContent: "",
    clientHeight: 120, scrollHeight: 60, scrollTop: 0,
    scrollIntoView() {},
    querySelector() { return fakeEl(); },
  };
}
function key(k: string, mods: any = {}) { return { key: k, preventDefault() {}, stopPropagation() {}, ...mods } as any; }

test("CopyMode: enter, move, visual-select, yank", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const scroll = fakeEl({ innerText: "alpha beta\ngamma delta\nepsilon" });
  let copied = "";
  const cm = new CopyMode({
    scroll: scroll as any, status: fakeEl() as any,
    onEnter() {}, onExit() {}, copyText(s) { copied = s; },
  });
  cm.enter();
  let st = cm.debugState();
  expect(st.mode).toBe("normal");
  expect(st.lines).toEqual(["alpha beta", "gamma delta", "epsilon"]);
  expect(st.cur).toEqual({ r: 2, c: 0 });          // enters at the bottom

  cm.handleKey(key("g")); cm.handleKey(key("g"));    // gg -> top
  expect(cm.debugState().cur).toEqual({ r: 0, c: 0 });
  cm.handleKey(key("w"));                             // -> "beta"
  expect(cm.debugState().cur).toEqual({ r: 0, c: 6 });
  cm.handleKey(key(" "));                             // Space begins selection (tmux)
  expect(cm.debugState().mode).toBe("visual");
  cm.handleKey(key("$"));                             // extend to end of line
  cm.handleKey(key("y"));                             // yank
  expect(copied).toBe("beta");
  expect(cm.active).toBe(false);                      // yank exits copy mode
});

test("CopyMode: Space no longer moves the cursor", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const cm = new CopyMode({ scroll: fakeEl({ innerText: "abcdef" }) as any, status: fakeEl() as any, onEnter() {}, onExit() {}, copyText() {} });
  cm.enter();
  cm.handleKey(key("g")); cm.handleKey(key("g"));
  cm.handleKey(key(" "));                             // Space -> select, cursor stays at 0
  expect(cm.debugState().cur).toEqual({ r: 0, c: 0 });
  expect(cm.debugState().mode).toBe("visual");
});

test("CopyMode: f<char> and W navigate within the line", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const cm = new CopyMode({ scroll: fakeEl({ innerText: "foo.bar baz" }) as any, status: fakeEl() as any, onEnter() {}, onExit() {}, copyText() {} });
  cm.enter();                                         // single line -> cursor {0,0}
  cm.handleKey(key("f")); cm.handleKey(key("b"));     // f b -> first 'b' at col 4
  expect(cm.debugState().cur).toEqual({ r: 0, c: 4 });
  cm.handleKey(key(";"));                             // ; -> next 'b' (in "baz") at col 8
  expect(cm.debugState().cur).toEqual({ r: 0, c: 8 });
  cm.handleKey(key("0")); cm.handleKey(key("W"));     // W -> 'baz' at col 8
  expect(cm.debugState().cur).toEqual({ r: 0, c: 8 });
});

test("CopyMode: counts and Escape leaves", () => {
  (globalThis as any).document = { addEventListener() {}, removeEventListener() {} };
  const scroll = fakeEl({ innerText: "l0\nl1\nl2\nl3\nl4" });
  const cm = new CopyMode({ scroll: scroll as any, status: fakeEl() as any, onEnter() {}, onExit() {}, copyText() {} });
  cm.enter();
  cm.handleKey(key("g")); cm.handleKey(key("g"));    // top
  cm.handleKey(key("3")); cm.handleKey(key("j"));    // 3j -> row 3
  expect(cm.debugState().cur.r).toBe(3);
  cm.handleKey(key("q"));
  expect(cm.active).toBe(false);
});
