.pragma library

// MarkdownLogic.js — markdown -> Qt rich text for the Hermes panel.
//
// Pure JS (no Qt/QML imports) so it can be unit-tested in node:
//   const src = fs.readFileSync("MarkdownLogic.js", "utf8").replace(/^\.pragma.*$/m, "");
//   eval(src); parseBlocks(text)
//
// Why not Qt's native Text.MarkdownText? It renders, but it drops chat-critical
// details: fenced code blocks get no slab/language/copy affordance, tables have
// no header tint, blockquotes are just indented, and single newlines inside a
// paragraph collapse into spaces (bad for chat transcripts). Here we parse the
// document ourselves, emit Qt's rich-text HTML subset (which *does* support
// tables with bordercolor/bgcolor, nested lists and <hr>), and let Qt lay it out.
//
// Output blocks:
//   { kind: "rich",    html: "...", muted: false }   paragraph/list/table/quote/hr
//   { kind: "heading", level: 1..6, html: "..." }
//   { kind: "code",    lang: "bash", text: "..." }
//
// Inline HTML is produced by inlineToHtml() and covers: `code`, [links](url),
// autolinks, **bold**, __bold__, *italic*, _italic_, ~~strike~~, \escapes.
// Anything that fails to parse is passed through literally (so half-streamed
// markdown never disappears).

var MONO_FAMILY = "monospace";
var DEFAULT_LIST_INDENT = 0;

// Fallback palette: only used when a caller does not pass theme colors (tests).
function defaultTheme() {
  return {
    text: "#dcdfe8",
    muted: "#9aa0b5",
    outline: "#3a3d52",
    tableHeader: "#232433",
    code: "#c9d1d9"
  };
}

// ============================================================================
// Escaping
// ============================================================================

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/"/g, "&quot;");
}

// Only http(s)/mailto survive; anything else (javascript:, data:) is left as
// literal text by returning "".
function safeUrl(url) {
  var u = String(url || "").trim();
  if (/^(https?:|mailto:)/i.test(u)) return u;
  return "";
}

// ============================================================================
// Inline markdown -> rich text
// ============================================================================

// Convert one line (or any inline run) of markdown into the HTML subset Qt's
// rich text engine renders. `theme` supplies the baked-in colors for inline
// code (Qt rich text supports background-color on spans only in QTextDocument,
// not in QQuickText, so code is distinguished by family + color instead).
function inlineToHtml(raw, theme) {
  var tx = theme || defaultTheme();
  var stash = [];

  function keep(html) {
    stash.push(html);
    return "\u0001" + (stash.length - 1) + "\u0001";
  }

  var s = String(raw == null ? "" : raw);

  // --- code spans (stashed before escaping so their content stays literal)
  s = s.replace(/`([^`]+)`/g, function (match, code) {
    return keep("<span style=\"font-family:" + MONO_FAMILY + "; color:" + tx.code + "\">" +
                escapeHtml(code) + "</span>");
  });

  // --- images: keep the alt text (inline images are not worth the layout cost)
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, function (match, alt, url) {
    var label = alt && alt !== "" ? alt : url;
    return keep("<span style=\"color:" + tx.muted + "\">" + escapeHtml(label) + "</span>");
  });

  // --- links (label may itself contain inline markup)
  s = s.replace(/\[([^\]]*)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)/g, function (match, label, url) {
    var clean = String(url).replace(/^</, "").replace(/>$/, "");
    var href = safeUrl(clean);
    if (!href) return match;
    return keep("<a href=\"" + escapeAttr(href) + "\">" +
                (label === "" ? escapeHtml(clean) : inlineToHtml(label, tx)) + "</a>");
  });

  // --- backslash escapes (\* \_ \` ...) — stashed as literals
  s = s.replace(/\\([\\`*_{}\[\]()#+\-.!~>|<])/g, function (match, ch) {
    return keep(escapeHtml(ch));
  });

  // Everything else is literal text now.
  s = escapeHtml(s);

  // --- bare URLs -> links
  s = s.replace(/(^|[\s(])((?:https?:\/\/|mailto:|www\.)[^\s<>()]+[^\s<>().,;:!?])/g,
    function (match, prefix, url) {
      var href = safeUrl(/^www\./i.test(url) ? "https://" + url : url);
      if (!href) return match;
      return prefix + "<a href=\"" + href + "\">" + url + "</a>";
    });

  // --- strong / strike / emphasis. Order matters: ** before *.
  s = s.replace(/\*\*([^\s*](?:[^*]*?[^\s*])?)\*\*/g, "<b>$1</b>");
  s = s.replace(/__([^\s_](?:[^_]*?[^\s_])?)__/g, "<b>$1</b>");
  s = s.replace(/~~([^\s~](?:[^~]*?[^\s~])?)~~/g, "<s>$1</s>");
  s = s.replace(/(^|[^\w*\\])\*([^\s*](?:[^*]*?[^\s*])?)\*(?=[^\w*]|$)/g,
    function (match, prefix, inner) { return prefix + "<i>" + inner + "</i>"; });
  s = s.replace(/(^|[^\w_\\])_([^\s_](?:[^_]*?[^\s_])?)_(?=[^\w_]|$)/g,
    function (match, prefix, inner) { return prefix + "<i>" + inner + "</i>"; });

  // --- restore stashed fragments
  s = s.replace(/\u0001(\d+)\u0001/g, function (match, index) {
    var value = stash[Number(index)];
    return value == null ? "" : value;
  });

  return s;
}

// ============================================================================
// Block helpers
// ============================================================================

function isBlank(line) {
  return /^\s*$/.test(line);
}

function fenceMatch(line) {
  return /^(\s{0,3})(`{3,}|~{3,})\s*([^\s`~]*)\s*$/.exec(line);
}

function headingMatch(line) {
  var m = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
  if (!m) return null;
  return { level: m[1].length, text: m[2] };
}

function isHr(line) {
  return /^\s{0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(line);
}

function isQuote(line) {
  return /^\s{0,3}>/.test(line);
}

function isSetextUnderline(line) {
  return /^\s{0,3}(=+|-{2,})\s*$/.test(line);
}

function listItemMatch(line) {
  var m = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/.exec(line);
  if (!m) return null;
  var indent = m[1].replace(/\t/g, "    ").length;
  var text = m[3];
  var checked = null;
  var box = /^\[([ xX])\]\s*(.*)$/.exec(text);
  if (box) {
    checked = box[1].toLowerCase() === "x";
    text = box[2];
  }
  var depth = 0;
  if (indent >= 2) depth = 1;
  if (indent >= 6) depth = 2;
  return {
    depth: depth,
    ordered: /\d/.test(m[2]),
    marker: m[2],
    text: text,
    checked: checked
  };
}

// Split a `| a | b |` table row into trimmed cells, honouring \| escapes.
function splitTableRow(line) {
  var s = String(line).trim();
  s = s.replace(/^\|/, "").replace(/\|$/, "");
  var cells = [];
  var current = "";
  for (var i = 0; i < s.length; i++) {
    var ch = s[i];
    if (ch === "\\" && s[i + 1] === "|") {
      current += "|";
      i++;
      continue;
    }
    if (ch === "|") {
      cells.push(current.trim());
      current = "";
      continue;
    }
    current += ch;
  }
  cells.push(current.trim());
  return cells;
}

function isTableDelimiter(line) {
  if (line.indexOf("-") < 0) return false;
  if (line.indexOf("|") < 0) return false;
  var cells = splitTableRow(line);
  if (cells.length === 0) return false;
  for (var i = 0; i < cells.length; i++) {
    if (!/^:?-+:?$/.test(cells[i])) return false;
  }
  return true;
}

function tableAligns(line) {
  var cells = splitTableRow(line);
  var aligns = [];
  for (var i = 0; i < cells.length; i++) {
    var text = cells[i];
    var left = text.charAt(0) === ":";
    var right = text.charAt(text.length - 1) === ":";
    if (left && right) aligns.push("center");
    else if (right) aligns.push("right");
    else aligns.push("");
  }
  return aligns;
}

// True when the line starts a non-paragraph block (used to end paragraphs).
function startsNewBlock(lines, index) {
  var line = lines[index];
  if (isBlank(line)) return true;
  if (fenceMatch(line)) return true;
  if (headingMatch(line)) return true;
  if (isHr(line)) return true;
  if (isQuote(line)) return true;
  if (listItemMatch(line)) return true;
  if (line.indexOf("|") >= 0 && index + 1 < lines.length && isTableDelimiter(lines[index + 1])) return true;
  return false;
}

// ============================================================================
// Block -> HTML builders
// ============================================================================

function listToHtml(items, theme) {
  var UL = "<ul style=\"margin-top:0;margin-bottom:0" +
           (DEFAULT_LIST_INDENT ? "; -qt-list-indent:" + DEFAULT_LIST_INDENT : "") + "\">";
  var html = "";
  var stack = [];          // stack of { ordered: bool }
  var lastDepth = -1;

  for (var k = 0; k < items.length; k++) {
    var item = items[k];
    // Never let an item jump more than one level: markdown writers indent
    // inconsistently and a gap would otherwise emit an empty wrapper list.
    var depth = lastDepth < 0 ? item.depth : Math.min(item.depth, lastDepth + 1);
    lastDepth = depth;

    while (stack.length > depth + 1) {
      html += "</li>" + (stack.pop().ordered ? "</ol>" : "</ul>");
    }

    if (stack.length === depth + 1) {
      html += "</li>";
      var top = stack[stack.length - 1];
      if (top.ordered !== item.ordered) {
        html += top.ordered ? "</ol>" : "</ul>";
        stack.pop();
        html += item.ordered ? "<ol style=\"margin-top:0;margin-bottom:0\">" : UL;
        stack.push({ ordered: item.ordered });
      }
    } else {
      html += item.ordered ? "<ol style=\"margin-top:0;margin-bottom:0\">" : UL;
      stack.push({ ordered: item.ordered });
    }

    var prefix = "";
    if (item.checked === true) prefix = "☑ ";
    else if (item.checked === false) prefix = "☐ ";
    html += "<li>" + prefix + item.html;
  }

  while (stack.length > 0) {
    html += "</li>" + (stack.pop().ordered ? "</ol>" : "</ul>");
  }
  return html;
}

function tableToHtml(header, rows, aligns, theme) {
  var tx = theme || defaultTheme();
  var columns = header ? header.length : 0;
  for (var r = 0; r < rows.length; r++) {
    if (rows[r].length > columns) columns = rows[r].length;
  }
  if (columns === 0) return "";

  function alignAttr(index) {
    var a = aligns && aligns[index] ? aligns[index] : "";
    return a ? " align=\"" + a + "\"" : "";
  }

  var html = "<table border=\"1\" bordercolor=\"" + tx.outline +
             "\" cellspacing=\"0\" cellpadding=\"5\" style=\"border-collapse:collapse\">";
  if (header && header.length > 0) {
    html += "<tr>";
    for (var c = 0; c < columns; c++) {
      html += "<td bgcolor=\"" + tx.tableHeader + "\"" + alignAttr(c) + "><b>" +
              (header[c] == null ? "" : header[c]) + "</b></td>";
    }
    html += "</tr>";
  }
  for (var row = 0; row < rows.length; row++) {
    html += "<tr>";
    for (var col = 0; col < columns; col++) {
      html += "<td" + alignAttr(col) + ">" + (rows[row][col] == null ? "" : rows[row][col]) + "</td>";
    }
    html += "</tr>";
  }
  return html + "</table>";
}

function quoteToHtml(lines, theme) {
  var tx = theme || defaultTheme();
  var parts = [];
  for (var i = 0; i < lines.length; i++) {
    var text = inlineToHtml(lines[i], tx);
    parts.push("<font color=\"" + tx.muted + "\">▎ " + text + "</font>");
  }
  return parts.join("<br>");
}

// ============================================================================
// parseBlocks
// ============================================================================

function parseBlocks(text, theme) {
  var tx = theme || defaultTheme();
  var src = String(text == null ? "" : text).replace(/\r\n?/g, "\n");
  var lines = src.split("\n");
  var total = lines.length;
  var blocks = [];
  var index = 0;

  while (index < total) {
    var line = lines[index];

    if (isBlank(line)) {
      index++;
      continue;
    }

    // ---- fenced code block. An unterminated fence consumes the rest of the
    // document: that is the correct mid-stream rendering (better a code slab
    // that keeps growing than raw backticks flickering until the model stops).
    var fence = fenceMatch(line);
    if (fence) {
      var marker = fence[2].charAt(0);
      var markerLength = fence[2].length;
      var body = [];
      var cursor = index + 1;
      while (cursor < total) {
        var closing = /^(\s{0,3})(`{3,}|~{3,})\s*$/.exec(lines[cursor]);
        if (closing && closing[2].charAt(0) === marker && closing[2].length >= markerLength) {
          cursor++;
          break;
        }
        body.push(lines[cursor]);
        cursor++;
      }
      blocks.push({ kind: "code", lang: fence[3] || "", text: body.join("\n") });
      index = cursor;
      continue;
    }

    // ---- table
    if (line.indexOf("|") >= 0 && index + 1 < total && isTableDelimiter(lines[index + 1])) {
      var header = splitTableRow(line);
      var aligns = tableAligns(lines[index + 1]);
      var rows = [];
      var rowIndex = index + 2;
      while (rowIndex < total && !isBlank(lines[rowIndex]) && lines[rowIndex].indexOf("|") >= 0) {
        rows.push(splitTableRow(lines[rowIndex]));
        rowIndex++;
      }
      blocks.push({ kind: "rich", muted: false, html: tableToHtml(header, rows, aligns, tx) });
      index = rowIndex;
      continue;
    }

    // ---- ATX heading
    var heading = headingMatch(line);
    if (heading) {
      blocks.push({ kind: "heading", level: heading.level, html: inlineToHtml(heading.text, tx) });
      index++;
      continue;
    }

    // ---- horizontal rule
    if (isHr(line)) {
      blocks.push({ kind: "rich", muted: false, html: "<hr>" });
      index++;
      continue;
    }

    // ---- blockquote
    if (isQuote(line)) {
      var quoteLines = [];
      while (index < total && isQuote(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s{0,3}>\s?/, ""));
        index++;
      }
      blocks.push({ kind: "rich", muted: true, html: quoteToHtml(quoteLines, tx) });
      continue;
    }

    // ---- list
    var firstItem = listItemMatch(line);
    if (firstItem) {
      var items = [];
      while (index < total) {
        var current = lines[index];
        var item = listItemMatch(current);
        if (item) {
          items.push({
            depth: item.depth,
            ordered: item.ordered,
            checked: item.checked,
            html: inlineToHtml(item.text, tx)
          });
          index++;
          continue;
        }
        // Lazily indented continuation of the previous item.
        if (items.length > 0 && !isBlank(current) && /^\s+\S/.test(current) &&
            !startsNewBlock(lines, index)) {
          items[items.length - 1].html += "<br>" + inlineToHtml(current.trim(), tx);
          index++;
          continue;
        }
        break;
      }
      blocks.push({ kind: "rich", muted: false, html: listToHtml(items, tx) });
      continue;
    }

    // ---- setext heading (underline form)
    if (index + 1 < total && isSetextUnderline(lines[index + 1]) && !isHr(line)) {
      var underline = lines[index + 1].trim();
      blocks.push({
        kind: "heading",
        level: underline.charAt(0) === "=" ? 1 : 2,
        html: inlineToHtml(line.trim(), tx)
      });
      index += 2;
      continue;
    }

    // ---- paragraph: consume until a blank line or another block starts.
    // Soft line breaks become <br>: chat messages are written line-by-line and
    // CommonMark's "join with a space" rule mangles them.
    var paragraph = [];
    while (index < total && !startsNewBlock(lines, index)) {
      paragraph.push(inlineToHtml(lines[index], tx));
      index++;
    }
    if (paragraph.length === 0) {
      // Defensive: never spin on a line we did not classify.
      paragraph.push(inlineToHtml(line, tx));
      index++;
    }
    blocks.push({ kind: "rich", muted: false, html: paragraph.join("<br>") });
  }

  return blocks;
}

// Convenience for non-QML callers / tests.
function toPlainText(blocks) {
  var out = [];
  for (var i = 0; i < blocks.length; i++) {
    var b = blocks[i];
    if (b.kind === "code") out.push(b.text);
    else out.push(String(b.html).replace(/<[^>]*>/g, ""));
  }
  return out.join("\n\n");
}
