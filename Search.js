// Pure helpers for the Spotlight plugin: scoring, menu parsing, calculator,
// and file ranking. Kept free of QML so the logic stays easy to reason about.

function norm(value) {
  return String(value || "").toLowerCase().trim()
}

// Split camelCase, dots, dashes, slashes into lowercase words.
function words(value) {
  return String(value || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(function(w) { return w.length > 0 })
}

// Every query char appears in order: "ffx" matches "firefox".
function isSubsequence(needle, hay) {
  var j = 0
  for (var i = 0; i < hay.length && j < needle.length; i++) {
    if (hay.charAt(i) === needle.charAt(j)) j++
  }
  return j === needle.length
}

// Initials: "vsc" matches "Visual Studio Code".
function initials(value) {
  return words(value).map(function(w) { return w.charAt(0) }).join("")
}

// 0 = no match. Higher is better. The label carries the score; extra text
// (generic name, keywords, path) can rescue a row but never outranks a
// label hit.
function score(query, label, extra) {
  var q = norm(query)
  if (!q) return 0
  var l = norm(label)
  if (!l) return 0

  if (l === q) return 100
  if (l.indexOf(q) === 0) return 90 - Math.min(10, l.length - q.length) * 0.5
  var ws = words(label)
  for (var i = 0; i < ws.length; i++) {
    if (ws[i].indexOf(q) === 0) return 75 - i
  }
  if (q.length >= 2 && initials(label).indexOf(q) === 0) return 70
  if (l.indexOf(q) >= 0) return 60
  // Multi-word queries in any order: "code visual" → Visual Studio Code.
  var qws = words(q)
  if (qws.length > 1) {
    var allMatch = qws.every(function(qw) {
      return ws.some(function(w) { return w.indexOf(qw) === 0 })
    })
    if (allMatch) return 55
  }
  if (q.length >= 2 && isSubsequence(q, l)) return 35

  var e = norm(extra)
  if (e) {
    var ew = words(extra)
    for (var k = 0; k < ew.length; k++) {
      if (ew[k].indexOf(q) === 0) return 30
    }
    if (q.length >= 3 && e.indexOf(q) >= 0) return 22
  }
  return 0
}

// ---- Omarchy menu actions --------------------------------------------------

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function parseMenu(raw) {
  try {
    var parsed = JSON.parse(stripJsonc(raw))
    if (!parsed || typeof parsed !== "object") return ({})
    return (parsed.items && typeof parsed.items === "object") ? parsed.items : parsed
  } catch (e) {
    return ({})
  }
}

// Flatten the menu tree into runnable actions with a breadcrumb such as
// "System" or "Style › Theme". Rows guarded by `when` are skipped: their
// condition is state-dependent (e.g. "Stop Screenrecording") and we don't
// want to offer actions that make no sense right now.
function menuActions(defaultRaw, userRaw) {
  var items = parseMenu(defaultRaw)
  var user = parseMenu(userRaw)
  for (var uid in user) items[uid] = user[uid]

  var out = []
  for (var id in items) {
    var it = items[id]
    if (!it || typeof it !== "object" || !it.action || it.when) continue
    var parts = id.split(".")
    var crumbs = []
    for (var p = 1; p < parts.length; p++) {
      var parentId = parts.slice(0, p).join(".")
      var parent = items[parentId]
      crumbs.push(parent && parent.label ? parent.label : parts[p - 1])
    }
    var aliases = Array.isArray(it.aliases) ? it.aliases.join(" ") : String(it.aliases || "")
    out.push({
      key: "action:" + id,
      label: String(it.label || id),
      detail: crumbs.length ? "Omarchy › " + crumbs.join(" › ") : "Omarchy",
      icon: String(it.icon || ""),
      iconFont: String(it.iconFont || ""),
      action: String(it.action),
      extra: crumbs.join(" ") + " " + aliases + " " + id
    })
  }
  return out
}

// ---- Scientific calculator --------------------------------------------------
// A small recursive-descent parser: nothing the user types is ever evaluated
// as JavaScript. Supports implicit multiplication (2pi, 3(4+1)), postfix
// factorial and percent, right-associative powers, DEG/RAD trig, base
// literals (0x, 0b, 0o), and `ans` for the previous result.

function gamma(x) {
  if (x < 0.5) return Math.PI / (Math.sin(Math.PI * x) * gamma(1 - x))
  x -= 1
  var g = 7
  var c = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
           -176.61502916214059, 12.507343278686905, -0.13857109526572012,
           9.9843695780195716e-6, 1.5056327351493116e-7]
  var a = c[0]
  var t = x + g + 0.5
  for (var i = 1; i < 9; i++) a += c[i] / (x + i)
  return Math.sqrt(2 * Math.PI) * Math.pow(t, x + 0.5) * Math.exp(-t) * a
}

function factorial(n) {
  if (n < 0 && Number.isInteger(n)) throw new Error("factorial of negative integer")
  if (Number.isInteger(n) && n <= 170) {
    var r = 1
    for (var i = 2; i <= n; i++) r *= i
    return r
  }
  return gamma(n + 1)
}

function gcd(a, b) {
  a = Math.abs(Math.round(a)); b = Math.abs(Math.round(b))
  while (b) { var t = b; b = a % b; a = t }
  return a
}

function intArg(x, name) {
  if (!Number.isInteger(x) || x < 0) throw new Error(name + " needs non-negative integers")
  return x
}

var CONSTANTS = {
  pi: Math.PI, "π": Math.PI, tau: 2 * Math.PI, "τ": 2 * Math.PI, e: Math.E,
  phi: (1 + Math.sqrt(5)) / 2, "φ": (1 + Math.sqrt(5)) / 2, inf: Infinity
}

// Function table. `ctx.toRad` / `ctx.fromRad` apply the angle mode.
var FUNCS = {
  sin:   function(c, a) { return Math.sin(c.toRad(a[0])) },
  cos:   function(c, a) { return Math.cos(c.toRad(a[0])) },
  tan:   function(c, a) { return Math.tan(c.toRad(a[0])) },
  sec:   function(c, a) { return 1 / Math.cos(c.toRad(a[0])) },
  csc:   function(c, a) { return 1 / Math.sin(c.toRad(a[0])) },
  cot:   function(c, a) { return 1 / Math.tan(c.toRad(a[0])) },
  asin:  function(c, a) { return c.fromRad(Math.asin(a[0])) },
  acos:  function(c, a) { return c.fromRad(Math.acos(a[0])) },
  atan:  function(c, a) { return c.fromRad(Math.atan(a[0])) },
  atan2: function(c, a) { return c.fromRad(Math.atan2(a[0], a[1])) },
  sinh:  function(c, a) { return Math.sinh(a[0]) },
  cosh:  function(c, a) { return Math.cosh(a[0]) },
  tanh:  function(c, a) { return Math.tanh(a[0]) },
  asinh: function(c, a) { return Math.asinh(a[0]) },
  acosh: function(c, a) { return Math.acosh(a[0]) },
  atanh: function(c, a) { return Math.atanh(a[0]) },
  sqrt:  function(c, a) { return Math.sqrt(a[0]) },
  cbrt:  function(c, a) { return Math.cbrt(a[0]) },
  root:  function(c, a) {   // root(x, n): n-th root, real for odd n of negatives
    var x = a[0], n = a.length > 1 ? a[1] : 2
    if (x < 0 && Number.isInteger(n) && n % 2 === 1) return -Math.pow(-x, 1 / n)
    return Math.pow(x, 1 / n)
  },
  exp:   function(c, a) { return Math.exp(a[0]) },
  ln:    function(c, a) { return Math.log(a[0]) },
  log:   function(c, a) { return a.length > 1 ? Math.log(a[0]) / Math.log(a[1]) : Math.log10(a[0]) },
  log10: function(c, a) { return Math.log10(a[0]) },
  log2:  function(c, a) { return Math.log2(a[0]) },
  abs:   function(c, a) { return Math.abs(a[0]) },
  sign:  function(c, a) { return Math.sign(a[0]) },
  floor: function(c, a) { return Math.floor(a[0]) },
  ceil:  function(c, a) { return Math.ceil(a[0]) },
  round: function(c, a) {   // round(x) or round(x, digits)
    var d = a.length > 1 ? a[1] : 0, f = Math.pow(10, d)
    return Math.round(a[0] * f) / f
  },
  trunc: function(c, a) { return Math.trunc(a[0]) },
  min:   function(c, a) { return Math.min.apply(null, a) },
  max:   function(c, a) { return Math.max.apply(null, a) },
  sum:   function(c, a) { return a.reduce(function(s, v) { return s + v }, 0) },
  avg:   function(c, a) { return a.reduce(function(s, v) { return s + v }, 0) / a.length },
  hypot: function(c, a) { return Math.hypot.apply(null, a) },
  mod:   function(c, a) { return ((a[0] % a[1]) + a[1]) % a[1] },
  fact:  function(c, a) { return factorial(a[0]) },
  gamma: function(c, a) { return gamma(a[0]) },
  ncr:   function(c, a) {
    var n = intArg(a[0], "nCr"), k = intArg(a[1], "nCr")
    if (k > n) return 0
    k = Math.min(k, n - k)
    var r = 1
    for (var i = 1; i <= k; i++) r = r * (n - k + i) / i
    return Math.round(r)
  },
  npr:   function(c, a) {
    var n = intArg(a[0], "nPr"), k = intArg(a[1], "nPr")
    if (k > n) return 0
    var r = 1
    for (var i = 0; i < k; i++) r *= (n - i)
    return r
  },
  gcd:   function(c, a) { return a.reduce(function(x, y) { return gcd(x, y) }) },
  lcm:   function(c, a) { return a.reduce(function(x, y) { return Math.abs(x * y) / gcd(x, y) }) },
  deg:   function(c, a) { return a[0] * 180 / Math.PI },   // radians → degrees
  rad:   function(c, a) { return a[0] * Math.PI / 180 }    // degrees → radians
}

function tokenize(src) {
  var tokens = []
  var i = 0
  while (i < src.length) {
    var ch = src.charAt(i)
    if (/\s/.test(ch)) { i++; continue }
    var m
    var rest = src.slice(i)
    // Base literals are flagged so "0xFF" on its own counts as a conversion.
    if ((m = rest.match(/^0x[0-9a-f]+/i))) { tokens.push({ t: "num", v: parseInt(m[0].slice(2), 16), base: true }); i += m[0].length; continue }
    if ((m = rest.match(/^0b[01]+/i)))     { tokens.push({ t: "num", v: parseInt(m[0].slice(2), 2), base: true });  i += m[0].length; continue }
    if ((m = rest.match(/^0o[0-7]+/i)))    { tokens.push({ t: "num", v: parseInt(m[0].slice(2), 8), base: true });  i += m[0].length; continue }
    if ((m = rest.match(/^(\d+\.?\d*|\.\d+)(e[+-]?\d+)?/i))) {
      tokens.push({ t: "num", v: parseFloat(m[0]) }); i += m[0].length; continue
    }
    if ((m = rest.match(/^[a-zπτφ][a-z0-9]*/i))) {
      tokens.push({ t: "id", v: m[0].toLowerCase() }); i += m[0].length; continue
    }
    if (rest.indexOf("**") === 0) { tokens.push({ t: "op", v: "^" }); i += 2; continue }
    if ("+-*/^%!(),×÷−·".indexOf(ch) >= 0) {
      var v = ch === "×" || ch === "·" ? "*" : (ch === "÷" ? "/" : (ch === "−" ? "-" : ch))
      tokens.push({ t: "op", v: v }); i++; continue
    }
    throw new Error("unexpected " + ch)
  }
  return tokens
}

// Evaluate an expression. opts: { mode: "deg"|"rad", ans: number, loose: bool }
// `loose` allows function application without parentheses ("sin 30").
function evaluate(src, opts) {
  opts = opts || {}
  var deg = opts.mode !== "rad"
  var ctx = {
    toRad: function(x) { return deg ? x * Math.PI / 180 : x },
    fromRad: function(x) { return deg ? x * 180 / Math.PI : x }
  }
  var tokens = tokenize(src)
  var pos = 0
  var usedOperator = false   // something beyond a bare number/constant

  function peek() { return tokens[pos] }
  function isOp(v) { var t = tokens[pos]; return t && t.t === "op" && t.v === v }
  function next() { return tokens[pos++] }
  function expect(v) {
    if (!isOp(v)) throw new Error("expected " + v)
    pos++
  }
  // Can the current token start an operand? Used for implicit multiplication.
  function startsOperand() {
    var t = peek()
    return t && (t.t === "num" || t.t === "id" || (t.t === "op" && t.v === "("))
  }

  function parseExpr() {
    var left = parseMul()
    while (isOp("+") || isOp("-")) {
      usedOperator = true
      var op = next().v
      var right = parseMul()
      left = op === "+" ? left + right : left - right
    }
    return left
  }

  function parseMul() {
    var left = parseUnary()
    for (;;) {
      if (isOp("*") || isOp("/")) {
        usedOperator = true
        var op = next().v
        var right = parseUnary()
        left = op === "*" ? left * right : left / right
      } else if (isOp("%") && tokens[pos + 1] && (tokens[pos + 1].t !== "op" || tokens[pos + 1].v === "(")) {
        // `a % b` is modulo; a trailing `%` is percent (handled in postfix).
        usedOperator = true
        next()
        var m = parseUnary()
        left = left % m
      } else if (peek() && peek().t === "id" && peek().v === "mod") {
        usedOperator = true
        next()
        var mm = parseUnary()
        left = ((left % mm) + mm) % mm
      } else if (startsOperand()) {
        usedOperator = true          // implicit multiplication: 2pi, 3(4)
        left = left * parseUnary()
      } else {
        return left
      }
    }
  }

  function parseUnary() {
    if (isOp("-")) { next(); usedOperator = true; return -parseUnary() }
    if (isOp("+")) { next(); return parseUnary() }
    return parsePow()
  }

  function parsePow() {
    var base = parsePostfix()
    if (isOp("^")) {
      usedOperator = true
      next()
      return Math.pow(base, parseUnary())   // right-associative, 2^-1 works
    }
    return base
  }

  function parsePostfix() {
    var v = parsePrimary()
    for (;;) {
      if (isOp("!")) { next(); usedOperator = true; v = factorial(v) }
      else if (isOp("%") && !(tokens[pos + 1] && (tokens[pos + 1].t !== "op" || tokens[pos + 1].v === "("))) {
        next(); usedOperator = true; v = v / 100
      }
      else return v
    }
  }

  function parsePrimary() {
    var t = next()
    if (!t) throw new Error("unexpected end")
    if (t.t === "num") {
      if (t.base) usedOperator = true
      return t.v
    }
    if (t.t === "op" && t.v === "(") {
      var inner = parseExpr()
      if (isOp(")")) next()          // tolerate a missing final ")"
      else if (pos < tokens.length) throw new Error("expected )")
      return inner
    }
    if (t.t === "id") {
      if (t.v === "ans") {
        if (typeof opts.ans !== "number") throw new Error("no previous answer")
        return opts.ans
      }
      if (FUNCS.hasOwnProperty(t.v)) {
        usedOperator = true
        var fn = FUNCS[t.v]
        var args = []
        if (isOp("(")) {
          next()
          if (!isOp(")")) {
            args.push(parseExpr())
            while (isOp(",")) { next(); args.push(parseExpr()) }
          }
          if (isOp(")")) next()
          else if (pos < tokens.length) throw new Error("expected )")
        } else if (opts.loose) {
          args.push(parseUnary())     // "sin 30", "sqrt 2"
        } else {
          throw new Error("call " + t.v + " with parentheses")
        }
        if (args.length === 0) throw new Error(t.v + " needs an argument")
        return fn(ctx, args)
      }
      if (CONSTANTS.hasOwnProperty(t.v)) return CONSTANTS[t.v]
      throw new Error("unknown " + t.v)
    }
    throw new Error("unexpected " + t.v)
  }

  var value = parseExpr()
  if (pos < tokens.length) throw new Error("unexpected " + tokens[pos].v)
  return { value: value, usedOperator: usedOperator }
}

// Format a number for display: ~12 significant digits, exponent for extremes,
// and no float noise like 0.30000000000000004 or sin(180°) = 1.2e-16.
function formatNumber(v) {
  if (v === Infinity) return "∞"
  if (v === -Infinity) return "−∞"
  if (isNaN(v)) return ""
  if (Math.abs(v) < 1e-12) return "0"
  var abs = Math.abs(v)
  if (abs >= 1e15 || abs < 1e-6) {
    return v.toExponential(9).replace(/\.?0+e/, "e").replace("e+", "e")
  }
  var s = Number(v.toPrecision(12)).toString()
  // Thousands separators on the integer part for readability.
  var parts = s.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

// Plain value for copying (no separators).
function plainNumber(v) {
  if (!isFinite(v)) return String(v)
  if (Math.abs(v) < 1e-12) return "0"
  return String(Number(v.toPrecision(12)))
}

// Returns null when the query isn't a calculation, otherwise
// { value, text, plain, expr, bases }.
// A leading "=" forces calculator mode (and allows "sin 30" without parens).
function calculate(query, opts) {
  var q = String(query || "").trim()
  var forced = q.charAt(0) === "="
  if (forced) q = q.slice(1).trim()
  if (!q) return null
  opts = opts || {}
  try {
    var r = evaluate(q, { mode: opts.mode, ans: opts.ans, loose: forced })
    // A bare number or constant ("42", "pi") is only math when forced.
    if (!forced && !r.usedOperator) return null
    if (typeof r.value !== "number" || isNaN(r.value)) return null
    var v = r.value
    var bases = ""
    if (Number.isInteger(v) && Math.abs(v) < 9007199254740992 && Math.abs(v) >= 2) {
      var sign = v < 0 ? "-" : ""
      var a = Math.abs(v)
      bases = "hex " + sign + "0x" + a.toString(16).toUpperCase() + "  ·  bin " + sign + "0b" + a.toString(2) + "  ·  oct " + sign + "0o" + a.toString(8)
      if (a.toString(2).length > 40) bases = "hex " + sign + "0x" + a.toString(16).toUpperCase()
    }
    return { value: v, text: formatNumber(v), plain: plainNumber(v), expr: q, bases: bases }
  } catch (e) {
    return null
  }
}

// Shown under "=" when the history is empty.
var CALC_HELP = [
  ["Trig", "sin cos tan  ·  asin acos atan atan2  ·  sec csc cot"],
  ["Hyperbolic", "sinh cosh tanh  ·  asinh acosh atanh"],
  ["Powers & logs", "x^y  sqrt cbrt root(x,n)  ·  exp ln log log(x,b) log2"],
  ["Counting", "5!  ·  nCr(n,k)  nPr(n,k)  ·  gcd lcm  ·  gamma"],
  ["Rounding", "round(x,digits) floor ceil trunc abs sign  ·  a mod b"],
  ["Lists", "min max sum avg hypot  (comma-separated)"],
  ["Constants", "pi π  e  tau  phi  ·  ans = last result  ·  50% = 0.5"],
  ["Bases & angles", "0xFF 0b101 0o17  ·  deg(x) rad(x)  ·  Ctrl+D toggles DEG/RAD"]
]

// ---- Files -----------------------------------------------------------------

function basename(path) {
  var p = String(path || "").replace(/\/+$/, "")
  var i = p.lastIndexOf("/")
  return i >= 0 ? p.slice(i + 1) : p
}

function dirname(path) {
  var p = String(path || "").replace(/\/+$/, "")
  var i = p.lastIndexOf("/")
  return i > 0 ? p.slice(0, i) : "/"
}

function tildify(path, home) {
  var p = String(path || "")
  return home && p.indexOf(home) === 0 ? "~" + p.slice(home.length) : p
}

function fileIcon(name, isDir) {
  if (isDir) return "󰉋"
  var ext = (String(name).match(/\.([a-z0-9]+)$/i) || [, ""])[1].toLowerCase()
  if (["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "avif"].indexOf(ext) >= 0) return "󰈟"
  if (["mp4", "mkv", "webm", "mov", "avi"].indexOf(ext) >= 0) return "󰈫"
  if (["mp3", "flac", "wav", "ogg", "m4a", "opus"].indexOf(ext) >= 0) return "󰈣"
  if (ext === "pdf") return "󰈦"
  if (["xlsx", "xls", "csv", "ods"].indexOf(ext) >= 0) return "󰈛"
  if (["docx", "doc", "odt", "rtf"].indexOf(ext) >= 0) return "󰈬"
  if (["pptx", "ppt", "odp"].indexOf(ext) >= 0) return "󰈧"
  if (["zip", "tar", "gz", "xz", "zst", "7z", "rar"].indexOf(ext) >= 0) return "󰗄"
  if (["md", "txt", "log"].indexOf(ext) >= 0) return "󰈙"
  if (["js", "ts", "py", "sh", "lua", "rs", "go", "qml", "json", "toml", "yaml", "yml", "c", "cpp", "h"].indexOf(ext) >= 0) return "󰈮"
  return "󰈔"
}

// fd prints one path per line; directories end in "/". Rank by how well the
// basename matches, then prefer shallower paths.
function rankFiles(raw, query, home, limit) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var isDir = line.charAt(line.length - 1) === "/"
    var path = line.replace(/\/+$/, "")
    var name = basename(path)
    var s = score(query, name, "")
    if (s === 0) s = 10
    var depth = path.split("/").length
    out.push({
      key: "file:" + path,
      label: name,
      detail: tildify(dirname(path), home),
      icon: fileIcon(name, isDir),
      path: path,
      isDir: isDir,
      score: s - depth * 0.3
    })
  }
  out.sort(function(a, b) { return b.score - a.score })
  return out.slice(0, limit)
}

if (typeof module !== "undefined") {
  module.exports = { score: score, menuActions: menuActions, calculate: calculate, evaluate: evaluate, rankFiles: rankFiles, words: words, CALC_HELP: CALC_HELP }
}
