/*
 * Plume editor bridge.
 *
 * Runs inside the WKWebView of the native macOS app. Wraps Vditor in
 * "instant rendering" (IR) mode and exposes a small API on window.Plume that
 * the Swift side drives. Messages to Swift go through
 * window.webkit.messageHandlers.plume.postMessage({type, ...}).
 */
(function () {
  "use strict";

  // Absolute URLs for the editor's own resources. They must not depend on the
  // <base> element, which is pointed at the document's folder so that relative
  // image paths in the Markdown resolve correctly.
  const APP_BASE = new URL(".", location.href).href;
  const CDN = new URL("vditor", APP_BASE).href.replace(/\/$/, "");
  const CONTENT_THEME_PATH = new URL("content-theme", APP_BASE).href.replace(/\/$/, "");

  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.plume;
  const post = (type, payload) => {
    const msg = Object.assign({ type: type }, payload || {});
    if (handler) {
      handler.postMessage(msg);
    } else {
      console.debug("[plume → native]", msg);
    }
  };

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const isDark = () => darkQuery.matches;

  const MARKDOWN_OPTIONS = {
    autoSpace: false,
    fixTermTypo: false,
    chinesePunct: false,
    gfmAutoLink: true,
    codeBlockPreview: true,
    mathBlockPreview: true,
    footnotes: true,
    toc: true,
    mark: true,
    sanitize: true,
    paragraphBeginningSpace: false,
    listStyle: false,
    linkBase: "",
    linkPrefix: "",
  };

  // The Vditor toolbar is hidden; the native menu bar drives these commands.
  // Hotkeys are blanked so that the native menu owns every shortcut.
  const TOOLBAR_ITEMS = [
    "headings", "bold", "italic", "strike", "link", "list", "ordered-list", "check",
    "outdent", "indent", "quote", "line", "code", "inline-code", "table",
    "undo", "redo", "edit-mode",
  ];

  let vditor = null;
  let ready = false;
  let dirtyPosted = false;
  let focusMode = false;
  let typewriterMode = false;
  let outlineTimer = 0;
  let lastOutlineKey = "";

  // ---------------------------------------------------------------- helpers

  const editorEl = () => vditor && vditor.vditor[vditor.vditor.currentMode].element;
  const mode = () => (vditor ? vditor.vditor.currentMode : "ir");

  function setBase(url) {
    let base = document.getElementById("doc-base");
    if (!base) {
      base = document.createElement("base");
      base.id = "doc-base";
      document.head.prepend(base);
    }
    base.href = url || APP_BASE;
  }

  function countStats(md) {
    // Strip the noisiest Markdown syntax before counting.
    const text = md
      .replace(/```[\s\S]*?```/g, (m) => m.replace(/^```.*$/gm, ""))
      .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/<[^>]+>/g, "")
      .replace(/[#>*_~`|\-=+]/g, " ");
    const cjk = (text.match(/[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]/g) || []).length;
    const latin = (text
      .replace(/[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]/g, " ")
      .match(/[A-Za-z0-9À-ɏ'’]+/g) || []).length;
    const chars = text.replace(/\s/g, "").length;
    const lines = md.length ? md.split("\n").length : 0;
    return { words: cjk + latin, chars: chars, lines: lines };
  }

  function headingText(el) {
    return (el.textContent || "")
      .replace(/​/g, "")
      .replace(/^\s*#{1,6}\s*/, "")
      .replace(/\s*\{#[^}]*\}\s*$/, "")
      .trim();
  }

  function headingsFromMarkdown(md) {
    const out = [];
    const lines = md.split("\n");
    let fence = null;
    let math = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const f = line.match(/^\s{0,3}(`{3,}|~{3,})/);
      if (f) {
        if (!fence) fence = f[1][0];
        else if (f[1][0] === fence) fence = null;
        continue;
      }
      if (fence) continue;
      if (/^\s*\$\$\s*$/.test(line)) { math = !math; continue; }
      if (math) continue;
      const m = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/);
      if (m) out.push({ level: m[1].length, text: m[2].replace(/[*_`~]/g, ""), line: i });
    }
    return out;
  }

  function headingElements() {
    const el = editorEl();
    if (!el) return [];
    if (mode() === "sv") {
      return Array.from(el.querySelectorAll('[data-type="heading-marker"]'));
    }
    return Array.from(el.querySelectorAll("h1, h2, h3, h4, h5, h6"));
  }

  function computeOutline() {
    if (!vditor) return [];
    if (mode() === "sv") {
      return headingsFromMarkdown(vditor.getValue());
    }
    return headingElements().map((h) => ({ level: Number(h.tagName.substring(1)), text: headingText(h) }));
  }

  function postOutline() {
    clearTimeout(outlineTimer);
    outlineTimer = setTimeout(() => {
      const items = computeOutline();
      const key = JSON.stringify(items);
      if (key === lastOutlineKey) return;
      lastOutlineKey = key;
      post("outline", { items: items });
    }, 150);
  }

  function postChange(md) {
    post("change", { markdown: md, stats: countStats(md) });
    postOutline();
  }

  // Fast sync: Vditor's own input callback waits for its undo delay, so we
  // also push the Markdown shortly after any DOM edit or menu command. This
  // keeps the native document current for saves, closes and quits.
  let syncTimer = 0;
  function scheduleSync(delay) {
    clearTimeout(syncTimer);
    syncTimer = setTimeout(() => {
      if (vditor) postChange(vditor.getValue());
    }, delay === undefined ? 150 : delay);
  }

  function clickToolbar(name) {
    const item = vditor.vditor.toolbar.elements[name];
    if (!item) return;
    item.children[0].dispatchEvent(new CustomEvent("click"));
  }

  function ensureFocus() {
    const el = editorEl();
    if (el && !el.contains(document.activeElement) && document.activeElement !== el) {
      const saved = vditor.vditor[mode()].range;
      el.focus();
      if (saved) {
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(saved);
      }
    }
  }

  function currentHeadingLevel() {
    const sel = window.getSelection();
    if (!sel.rangeCount) return 0;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== editorEl()) {
      if (node.nodeType === 1 && /^H[1-6]$/.test(node.tagName)) return Number(node.tagName[1]);
      node = node.parentNode;
    }
    return 0;
  }

  function setHeading(level) {
    ensureFocus();
    const item = vditor.vditor.toolbar.elements.headings;
    if (!item) return;
    const actionBtn = item.children[0];
    if (level === 0) {
      if (currentHeadingLevel() === 0) return;
      actionBtn.classList.add("vditor-menu--current");
      actionBtn.dispatchEvent(new CustomEvent("click"));
      return;
    }
    const panel = item.querySelector(".vditor-hint, .vditor-panel");
    const btn = panel && panel.querySelector('button[data-tag="h' + level + '"]');
    if (btn) btn.dispatchEvent(new CustomEvent("click"));
  }

  function insertBlock(markdown) {
    ensureFocus();
    vditor.insertMD(markdown);
  }

  // ------------------------------------------------------------- focus mode

  function updateActiveBlock() {
    const el = editorEl();
    if (!el) return;
    const sel = window.getSelection();
    let block = null;
    if (sel.rangeCount && el.contains(sel.anchorNode)) {
      block = sel.anchorNode;
      while (block && block.parentNode !== el) block = block.parentNode;
    }
    el.querySelectorAll(":scope > .plume-active").forEach((n) => {
      if (n !== block) n.classList.remove("plume-active");
    });
    if (block && block.nodeType === 1) block.classList.add("plume-active");
  }

  // ------------------------------------------------------------ init vditor

  function create() {
    const toolbar = TOOLBAR_ITEMS.map((name) => ({ name: name, hotkey: "" }));
    vditor = new Vditor("editor", {
      cdn: CDN,
      lang: "zh_CN",
      mode: "ir",
      height: "auto",
      width: "100%",
      value: "",
      icon: "ant",
      theme: isDark() ? "dark" : "classic",
      placeholder: "",
      undoDelay: 500,
      cache: { enable: false },
      toolbar: toolbar,
      toolbarConfig: { hide: true, pin: false },
      counter: { enable: false },
      outline: { enable: false },
      link: { isOpen: false },
      image: { isPreview: false },
      hint: { emojiPath: CDN + "/dist/images/emoji", delay: 150 },
      preview: {
        maxWidth: 860,
        delay: 500,
        mode: "editor",
        markdown: MARKDOWN_OPTIONS,
        hljs: { enable: true, style: isDark() ? "github-dark" : "github", lineNumber: false },
        math: { engine: "KaTeX", inlineDigit: true },
        theme: { current: isDark() ? "dark" : "light", path: CONTENT_THEME_PATH },
        actions: [],
      },
      upload: {
        accept: "image/*",
        multiple: true,
        handler: uploadHandler,
      },
      input: (md) => {
        postChange(md);
      },
      after: () => {
        ready = true;
        hookEvents();
        applyTheme();
        post("ready", { version: vditor.version });
      },
    });
  }

  function uploadHandler(files) {
    const list = Array.from(files);
    return Promise.all(list.map((file) => new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => {
        const data = String(reader.result);
        resolve({ name: file.name, type: file.type, data: data.substring(data.indexOf(",") + 1) });
      };
      reader.onerror = () => resolve(null);
      reader.readAsDataURL(file);
    }))).then((items) => {
      post("saveFiles", { files: items.filter(Boolean) });
      return null;
    });
  }

  function hookEvents() {
    const root = vditor.vditor.element;

    // Immediate "document edited" signal; the full Markdown follows via the
    // debounced Vditor input callback.
    root.addEventListener("input", () => {
      if (!dirtyPosted) {
        dirtyPosted = true;
        post("dirty");
      }
      scheduleSync();
    }, true);

    // F8 / F9 toggle focus and typewriter mode (handled natively).
    document.addEventListener("keydown", (event) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key === "F8" || event.key === "F9") {
        event.preventDefault();
        post("shortcut", { name: event.key === "F8" ? "focus" : "typewriter" });
      }
    }, true);

    // ⌘-click opens links and images, as in other Markdown editors.
    root.addEventListener("click", (event) => {
      if (!event.metaKey) return;
      const target = event.target;
      let url = null;
      const irLink = target.closest && target.closest('[data-type="a"]');
      if (irLink) {
        const marker = irLink.querySelector(":scope > .vditor-ir__marker--link");
        url = marker && marker.textContent;
      }
      if (!url && target.closest) {
        const a = target.closest("a[href]");
        if (a) url = a.getAttribute("href");
      }
      if (!url && target.tagName === "IMG") url = target.getAttribute("src");
      if (url) {
        event.preventDefault();
        event.stopPropagation();
        post("openLink", { url: url.trim() });
      }
    }, true);

    // Keep the host informed of the caret for focus mode.
    document.addEventListener("selectionchange", () => {
      if (focusMode) updateActiveBlock();
    });

    // Keep native window focus behaviour sane: Escape blurs nothing.
    window.addEventListener("dragover", (e) => e.preventDefault());
    window.addEventListener("drop", (e) => {
      if (!root.contains(e.target)) e.preventDefault();
    });
  }

  const DIAGRAM_SELECTOR = [
    "mermaid", "flowchart", "graphviz", "echarts", "markmap", "mindmap", "abc", "smiles",
  ].map((l) => '[data-type="code-block"] .language-' + l).join(",");

  let appliedDark = null;
  function applyTheme() {
    const dark = isDark();
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    if (vditor && ready) {
      vditor.setTheme(dark ? "dark" : "classic", dark ? "dark" : "light", dark ? "github-dark" : "github");
      // Diagrams are rendered with the theme current at render time.
      if (appliedDark !== null && appliedDark !== dark && editorEl() && editorEl().querySelector(DIAGRAM_SELECTOR)) {
        const y = window.scrollY;
        vditor.setValue(vditor.getValue(), false);
        window.scrollTo(0, y);
      }
      appliedDark = dark;
    }
  }

  function placeCaretAtStart() {
    const el = editorEl();
    if (!el) return;
    el.focus({ preventScroll: true });
    // Put the caret before the first real text, after any syntax marker
    // (e.g. the "# " of a heading), so typing never breaks the first block.
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => (node.parentElement && node.parentElement.closest(".vditor-ir__marker, .vditor-sv__marker, .vditor-ir__preview")
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const text = walker.nextNode();
    const range = document.createRange();
    if (text) {
      range.setStart(text, 0);
    } else {
      range.setStart(el.firstElementChild || el, 0);
    }
    range.collapse(true);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    window.scrollTo(0, 0);
  }

  darkQuery.addEventListener("change", applyTheme);

  // ------------------------------------------------------- public API (Swift)

  const Plume = {
    /** Load a document. baseURL is the folder used to resolve relative links. */
    load(opts) {
      setBase(opts.baseURL);
      vditor.setValue(opts.markdown || "", true);
      dirtyPosted = false;
      lastOutlineKey = "";
      postOutline();
      post("stats", { stats: countStats(opts.markdown || "") });
      window.scrollTo(0, 0);
      if (opts.focus !== false) {
        setTimeout(placeCaretAtStart, 0);
      }
      return true;
    },

    /** Replace content (e.g. after the file changed on disk) keeping scroll. */
    reload(markdown) {
      const y = window.scrollY;
      vditor.setValue(markdown || "", true);
      dirtyPosted = false;
      postOutline();
      post("stats", { stats: countStats(markdown || "") });
      window.scrollTo(0, y);
      return true;
    },

    setBase(url) {
      setBase(url);
      // Re-render so relative images resolve against the new folder.
      const md = vditor.getValue();
      const y = window.scrollY;
      vditor.setValue(md, false);
      window.scrollTo(0, y);
      return true;
    },

    getMarkdown() {
      return vditor ? vditor.getValue() : "";
    },

    markClean() {
      dirtyPosted = false;
      return true;
    },

    focus() {
      if (vditor) vditor.focus();
      return true;
    },

    command(name) {
      if (!vditor) return false;
      const result = runCommand(name);
      scheduleSync(80);
      return result;
    },

    insertText(text) {
      ensureFocus();
      vditor.insertMD(text);
      scheduleSync(80);
      return true;
    },

    collapseSelection() {
      const sel = window.getSelection();
      if (sel.rangeCount) sel.collapseToStart();
      return true;
    },

    selectedText() {
      return window.getSelection().toString();
    },

    insertMarkdown(md) {
      ensureFocus();
      vditor.insertMD(md);
      scheduleSync(80);
      return true;
    },

    /** Insert an image or link list produced by the native side. */
    insertFiles(items) {
      ensureFocus();
      const md = items.map((it) => (it.image ? "![" + it.alt + "](" + it.path + ")" : "[" + it.alt + "](" + it.path + ")")).join("\n");
      vditor.insertMD(md);
      post("dirty");
      scheduleSync(80);
      return true;
    },

    setMode(target) {
      if (!vditor || mode() === target) return mode();
      const item = vditor.vditor.toolbar.elements["edit-mode"];
      const btn = item && item.querySelector('button[data-mode="' + target + '"]');
      if (btn) btn.dispatchEvent(new CustomEvent("click"));
      document.documentElement.dataset.mode = mode();
      lastOutlineKey = "";
      postOutline();
      setTimeout(() => vditor.focus(), 0);
      post("mode", { mode: mode() });
      return mode();
    },

    toggleSourceMode() {
      return Plume.setMode(mode() === "sv" ? "ir" : "sv");
    },

    scrollToHeading(index) {
      const list = headingElements();
      const el = list[index];
      if (!el) return false;
      const top = el.getBoundingClientRect().top + window.scrollY - 24;
      window.scrollTo({ top: top, behavior: "smooth" });
      return true;
    },

    setFocusMode(on) {
      focusMode = !!on;
      document.body.classList.toggle("plume-focus", focusMode);
      if (focusMode) updateActiveBlock();
      return focusMode;
    },

    setTypewriterMode(on) {
      typewriterMode = !!on;
      document.body.classList.toggle("plume-typewriter", typewriterMode);
      if (vditor) vditor.vditor.options.typewriterMode = typewriterMode;
      return typewriterMode;
    },
  };

  function runCommand(name) {
    {
      const m = /^heading-(\d)$/.exec(name);
      if (m) {
        setHeading(Number(m[1]));
        return true;
      }
      switch (name) {
        case "heading-up": {
          const lvl = currentHeadingLevel();
          setHeading(lvl === 0 ? 6 : Math.max(1, lvl - 1));
          return true;
        }
        case "heading-down": {
          const lvl = currentHeadingLevel();
          if (lvl === 0) return true;
          setHeading(lvl === 6 ? 0 : lvl + 1);
          return true;
        }
        case "math-block":
          insertBlock("$$\n\n$$\n");
          return true;
        case "highlight":
          ensureFocus();
          wrapSelection("==", "==");
          return true;
        default:
          ensureFocus();
          clickToolbar(name);
          return true;
      }
    }
  }

  Object.assign(Plume, {
    /** Count case-insensitive occurrences in the rendered text. */
    countMatches(query, caseSensitive) {
      if (!query) return 0;
      const text = (editorEl() || document.body).innerText || "";
      const hay = caseSensitive ? text : text.toLowerCase();
      const needle = caseSensitive ? query : query.toLowerCase();
      let count = 0;
      let i = hay.indexOf(needle);
      while (i !== -1) {
        count++;
        i = hay.indexOf(needle, i + needle.length);
      }
      return count;
    },

    /** Replace the current selection (selected by the native find) with text. */
    replaceSelection(query, replacement, caseSensitive) {
      const sel = window.getSelection();
      if (!sel.rangeCount) return false;
      const selected = sel.toString();
      const matches = caseSensitive ? selected === query : selected.toLowerCase() === query.toLowerCase();
      if (!matches) return false;
      ensureFocus();
      document.execCommand("insertText", false, replacement);
      return true;
    },

    replaceAll(query, replacement, caseSensitive) {
      if (!query) return 0;
      const md = vditor.getValue();
      const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const re = new RegExp(escaped, caseSensitive ? "g" : "gi");
      const count = (md.match(re) || []).length;
      if (!count) return 0;
      const next = md.replace(re, () => replacement);
      const y = window.scrollY;
      vditor.setValue(next, false);
      window.scrollTo(0, y);
      post("dirty");
      postChange(next);
      return count;
    },

    /** Render the document into #print-root for printing / PDF / HTML export. */
    async renderForExport() {
      const root = document.getElementById("print-root");
      const md = vditor.getValue();
      root.innerHTML = "";
      await Vditor.preview(root, md, {
        cdn: CDN,
        mode: "light",
        lang: "zh_CN",
        anchor: 0,
        markdown: MARKDOWN_OPTIONS,
        hljs: { enable: true, style: "github", lineNumber: false },
        math: { engine: "KaTeX", inlineDigit: true },
        theme: { current: isDark() ? "dark" : "light", path: CONTENT_THEME_PATH },
        lazyLoadImage: "",
      });
      // Give async renderers (math, diagrams) and images a moment to finish.
      const images = Array.from(root.querySelectorAll("img"));
      await Promise.all(images.map((img) => (img.complete ? null : new Promise((r) => {
        img.addEventListener("load", r, { once: true });
        img.addEventListener("error", r, { once: true });
      }))));
      const hasDiagrams = root.querySelector(".language-mermaid, .language-flowchart, .language-graphviz, .language-markmap, .language-echarts, .language-math, .language-abc, .language-smiles, .language-mindmap");
      await new Promise((r) => setTimeout(r, hasDiagrams ? 1200 : 150));
      return root.innerHTML;
    },

    clearExport() {
      document.getElementById("print-root").innerHTML = "";
      return true;
    },

    info() {
      return { ready: ready, mode: mode(), version: vditor && vditor.version };
    },
  });

  function wrapSelection(prefix, suffix) {
    const sel = window.getSelection();
    const text = sel.rangeCount ? sel.toString() : "";
    document.execCommand("insertText", false, prefix + text + suffix);
  }

  window.Plume = Plume;
  document.documentElement.dataset.theme = isDark() ? "dark" : "light";
  document.documentElement.dataset.mode = "ir";
  create();
})();
