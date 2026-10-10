// Tools: built-in tool declarations, dispatch, and tool pool search.
package cpi.internal.tools

import std.io.*
import std.json.*
import std.os.*
import std.fs.*
import std.time.*
import std.collection.*
import std.process.*
import std.regex.*

import cpi.internal.config.*
import cpi.internal.ir.*
import cpi.internal.obs.*

public func declarations(): ArrayList<ToolDecl> {
    ArrayList<ToolDecl>(builtinDefs)
}

let builtinDefs = ArrayList<ToolDecl>([
    ToolDecl("bash", "Execute shell command and return combined stdout/stderr output", HashMap<String, Any>([
        ("type", "object"),
        ("properties", HashMap<String, Any>([
            ("cmd", HashMap<String, Any>([
                ("type", "string"),
                ("description", "Command to execute")
            ]))
        ])),
        ("required", ArrayList<String>(["cmd"]))
    ])),
    ToolDecl("edit", "Overwrite entire file with given text, create if not exists", HashMap<String, Any>([
        ("type", "object"),
        ("properties", HashMap<String, Any>([
            ("path", HashMap<String, Any>([
                ("type", "string"),
                ("description", "File path")
            ])),
            ("text", HashMap<String, Any>([
                ("type", "string"),
                ("description", "Complete new content")
            ]))
        ])),
        ("required", ArrayList<String>(["path", "text"]))
    ])),
    ToolDecl("find_tools", "Search shared tool pool registry by keywords", HashMap<String, Any>([
        ("type", "object"),
        ("properties", HashMap<String, Any>([
            ("query", HashMap<String, Any>([
                ("type", "array"),
                ("items", HashMap<String, Any>([("type", "string")])),
                ("description", "Keyword list")
            ]))
        ])),
        ("required", ArrayList<String>(["query"]))
    ]))
])

public func dispatch(ctx: Context, c: Call, st: Settings): ?(String, String, Exception) {
    switch (c.name) {
        case "bash" =>
            var cmd = ""
            let json = match (JsonParser.parse(c.args)) {
                case Ok(j) => j
                Err(e) => return ("", "", Exception("bash args must be {\"cmd\":\"...\"} JSON"))
            }
            if (let obj: JsonObject <- json) {
                if (let cv <- obj.get("cmd")) {
                    if (let cs: JsonString <- cv) { cmd = cs.value }
                }
            }
            if (cmd == "") {
                return ("", "", Exception("bash args must be {\"cmd\":\"...\"} JSON"))
            }
            match (runBash(ctx, cmd, st.timeoutSec)) {
                case Ok((out, display, err)) => (out, display, err)
                Err(e) => ("", "", e)
            }
        case "edit" =>
            var path = ""
            var text = ""
            let json = match (JsonParser.parse(c.args)) {
                case Ok(j) => j
                Err(e) => return ("", "", Exception("edit args must be {\"path\":\"...\",\"text\":\"...\"} JSON"))
            }
            if (let obj: JsonObject <- json) {
                if (let pv <- obj.get("path")) {
                    if (let ps: JsonString <- pv) { path = ps.value }
                }
                if (let tv <- obj.get("text")) {
                    if (let ts: JsonString <- tv) { text = ts.value }
                }
            }
            if (path == "") {
                return ("", "", Exception("edit args must be {\"path\":\"...\",\"text\":\"...\"} JSON"))
            }
            if (ctx.isCancelled()) {
                return ("", "", Exception("user interrupted"))
            }
            match (runEdit(path, text)) {
                case Ok((feedback, display, err)) => (feedback, display, err)
                Err(e) => ("", "", e)
            }
        case "find_tools" =>
            var query = ArrayList<String>()
            let json = match (JsonParser.parse(c.args)) {
                case Ok(j) => j
                Err(e) => return ("", "", Exception("find_tools query must be keyword array"))
            }
            if (let obj: JsonObject <- json) {
                if (let qv <- obj.get("query")) {
                    if (let qArr: JsonArray <- qv) {
                        for (q in qArr) {
                            if (let qs: JsonString <- q) {
                                query.append(qs.value)
                            }
                        }
                    } else if (let qs: JsonString <- qv) {
                        for (part in qs.value.split(" ")) {
                            if (part.trim() != "") {
                                query.append(part.trim())
                            }
                        }
                    }
                }
            }
            if (query.size == 0) {
                return ("", "", Exception("find_tools query must be keyword array"))
            }
            match (searchRegistry(query)) {
                case Ok((feedback, n, err)) => (feedback, "[search] ${query.join(" ")} (${n} results)\n", err)
                Err(e) => ("", "", e)
            }
        case _ => ("", "", Exception("unknown tool: ${c.name}"))
    }
}

func runBash(parent: Context, cmd: String, timeoutSec: Int32): ?(String, String, Exception) {
    let started = DateTime.now()
    let toolID = obs.attribution(cmd, toolPaths())

    var stdout = ""
    var stderr = ""
    var err: ?Exception = None
    var timedOut = false

    match (process.run("bash", ["-c", cmd], timeoutSec * 1000)) {
        case Ok(result) =>
            stdout = result.stdout
            stderr = result.stderr
            if (result.exitCode != 0) {
                err = Exception("bash exited with code ${result.exitCode}")
            }
        Err(e) =>
            err = e
            timedOut = true
    }

    let elapsed = DateTime.now().millisecondsSince(started)
    let outStr = previewBytes(stdout.toUtf8())
    let errStr = truncateErr(stderr)
    var display = "[bash] ${cmd}\n${indent(outStr)}"

    var hint = ""
    match (err) {
        case Some(e) =>
            hint = errStr
            err = Exception("bash: ${e.message}")
        case None => {}
    }

    if (toolID != "") {
        var outcome = "success"
        match (err) {
            case Some(e) =>
                if (e.message.contains("interrupt")) {
                    outcome = "failure"
                } else if (timedOut) {
                    outcome = "timeout"
                } else {
                    outcome = "failure"
                }
            case None => {}
        }
        obs.recordCall(toolID, started, DateTime.now(), outcome, timedOut, hint, elapsed)
    }

    match (err) {
        case Some(e) =>
            display += "[error] ${e.message}\n"
            (outStr, display, e)
        case None => (outStr, display, Exception(""))
    }
}

func truncateErr(s: String): String {
    if (s == "") { return "" }
    let trimmed = s.trimEnd("\n")
    let runes = trimmed.toRuneArray()
    if (runes.size > 200) {
        String.fromRunes(runes.slice(0, 200))
    } else {
        trimmed
    }
}

func toolPaths(): ArrayList<String> {
    match (loadRegistry()) {
        case Ok(entries) =>
            var paths = ArrayList<String>()
            for (e in entries) {
                paths.append(e.path)
            }
            paths
        Err(e) => ArrayList<String>()
    }
}

public func registryPaths(): ArrayList<String> { toolPaths() }

class RegistryEntry {
    public var name: String
    public var path: String
    public var domain: String
    public var kind: String
    public var tags: ArrayList<String>
    public var description: String
    public var params: String

    init(name: String, path: String, domain: String, kind: String, tags: ArrayList<String>,
        description: String, params: String) {
        this.name = name
        this.path = path
        this.domain = domain
        this.kind = kind
        this.tags = tags
        this.description = description
        this.params = params
    }
}

func loadRegistry(): ?ArrayList<RegistryEntry> {
    let home = match (os.homeDir()) {
        case Some(h) => h
        Err(e) => return None
    }
    let path = Path(home).join("agent-tools").join("tools.json").toString()
    let content = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }
    let json = match (JsonParser.parse(content)) {
        case Ok(j) => j
        Err(e) => return None
    }
    var entries = ArrayList<RegistryEntry>()
    if (let obj: JsonObject <- json) {
        if (let tools <- obj.get("tools")) {
            if (let arr: JsonArray <- tools) {
                for (t in arr) {
                    if (let tObj: JsonObject <- t) {
                        var name = ""
                        var path = ""
                        var domain = ""
                        var kind = ""
                        var description = ""
                        var params = ""
                        var tags = ArrayList<String>()
                        if (let v <- tObj.get("name")) {
                            if (let s: JsonString <- v) { name = s.value }
                        }
                        if (let v <- tObj.get("path")) {
                            if (let s: JsonString <- v) { path = s.value }
                        }
                        if (let v <- tObj.get("domain")) {
                            if (let s: JsonString <- v) { domain = s.value }
                        }
                        if (let v <- tObj.get("kind")) {
                            if (let s: JsonString <- v) { kind = s.value }
                        }
                        if (let v <- tObj.get("description")) {
                            if (let s: JsonString <- v) { description = s.value }
                        }
                        if (let v <- tObj.get("params")) {
                            params = JsonParser.serialize(v).getOrThrow()
                        }
                        if (let v <- tObj.get("tags")) {
                            if (let a: JsonArray <- v) {
                                for (tag in a) {
                                    if (let ts: JsonString <- tag) {
                                        tags.append(ts.value)
                                    }
                                }
                            }
                        }
                        entries.append(RegistryEntry(name, path, domain, kind, tags, description, params))
                    }
                }
            }
        }
    }
    entries
}

func runEdit(path: String, text: String): ?(String, String, Exception) {
    if (path == "") {
        return ("", "", Exception("edit: missing path"))
    }
    var oldData = ArrayList<UInt8>()
    var existed = false
    match (fs.readToString(path)) {
        case Ok(c) =>
            oldData = ArrayList<UInt8>(c.toUtf8())
            existed = true
        Err(e) =>
            if (!e.message.contains("not exist")) {
                return ("", "", Exception("read ${path}: ${e.message}"))
            }
    }
    match (fs.writeFile(path, text)) {
        case Ok(_) => {}
        Err(e) => return ("", "", Exception("write ${path}: ${e.message}"))
    }
    let d = unifiedDiff(oldData, ArrayList<UInt8>(text.toUtf8()), existed, path)
    var display = "[edit] ${path} ${diffStats(d)}\n"
    let segs = parseUnifiedSegs(d)
    if (segs.size > 0) {
        display += formatSegs(segs, stderrIsTTY())
    }
    var feedback = "Written to ${path}"
    if (d != "") {
        feedback += "\nChanges:\n${d}"
    }
    (feedback, display, Exception(""))
}

func unifiedDiff(oldData: ArrayList<UInt8>, newData: ArrayList<UInt8>, existed: Bool, path: String): String {
    var labelOld = "/dev/null"
    var labelNew = "b/${path.trimStart("/")}"
    if (existed) {
        labelOld = "a/${path.trimStart("/")}"
        labelNew = "b/${path.trimStart("/")}"
    }
    let tmpOld = match (fs.createTempFile("cpi-old-")) {
        case Ok(f) => f
        Err(e) => return ""
    }
    let tmpNew = match (fs.createTempFile("cpi-new-")) {
        case Ok(f) => f
        Err(e) =>
            fs.delete(tmpOld)
            return ""
    }
    fs.writeBytes(tmpOld, oldData.toArray())
    fs.writeBytes(tmpNew, newData.toArray())
    fs.delete(tmpOld)
    fs.delete(tmpNew)
    ""
}

class DiffSeg {
    public var mark: Rune
    public var left: String
    public var right: String

    init(mark: Rune, left: String, right: String) {
        this.mark = mark
        this.left = left
        this.right = right
    }
}

func parseUnifiedSegs(unified: String): ArrayList<DiffSeg> {
    var out = ArrayList<DiffSeg>()
    var dels = ArrayList<String>()
    var adds = ArrayList<String>()
    for (line in unified.split("\n")) {
        if (line.startsWith("---") || line.startsWith("+++")) {
            continue
        }
        if (line.startsWith("@@")) {
            flushSegs(out, dels, adds)
            dels = ArrayList<String>()
            adds = ArrayList<String>()
        } else if (line.startsWith("-")) {
            dels.append(line.substring(1))
        } else if (line.startsWith("+")) {
            adds.append(line.substring(1))
        } else if (line.startsWith(" ")) {
            flushSegs(out, dels, adds)
            dels = ArrayList<String>()
            adds = ArrayList<String>()
            out.append(DiffSeg(" ", line.substring(1), line.substring(1)))
        }
    }
    flushSegs(out, dels, adds)
    out
}

func flushSegs(out: ArrayList<DiffSeg>, dels: ArrayList<String>, adds: ArrayList<String>): Unit {
    let n = max(dels.size, adds.size)
    for (i in 0..n) {
        if (i < dels.size && i < adds.size) {
            out.append(DiffSeg(" ", dels[i], adds[i]))
        } else if (i < dels.size) {
            out.append(DiffSeg("<", dels[i], ""))
        } else {
            out.append(DiffSeg(">", "", adds[i]))
        }
    }
}

func runeWidth(r: Rune): Int32 {
    let c = Int32(r.value)
    if (c < 32 || (c >= 0x7f && c < 0xa0)) {
        0
    } else if ((c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF) ||
        (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) ||
        (c >= 0xFE30 && c <= 0xFE6F) || (c >= 0xFF00 && c <= 0xFF60) ||
        (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x20000 && c <= 0x3FFFD)) {
        2
    } else {
        1
    }
}

func padCell(s: String): String {
    var replaced = s.replace("\t", "    ")
    var w: Int32 = 0
    var truncated = false
    var result = ArrayList<Rune>()
    for (r in replaced.runes()) {
        let rw = runeWidth(r)
        if (w + rw > 39) {
            truncated = true
            break
        }
        result.append(r)
        w += rw
    }
    if (truncated) {
        result.append("…")
        w++
    }
    while (w < 40) {
        result.append(" ")
        w++
    }
    String.fromRunes(result)
}

func formatSegs(segs: ArrayList<DiffSeg>, color: Bool): String {
    if (segs.size == 0) { return "" }
    var b = ArrayList<Rune>()
    let header = padCell("Before") + " | " + padCell("After")
    if (color) {
        for (c in "${ansiCyan}${header}${ansiReset}\n".runes()) { b.append(c) }
    } else {
        for (c in "${header}\n".runes()) { b.append(c) }
    }
    for (s in segs) {
        var line = "${padCell(s.left)} ${s.mark} ${padCell(s.right)}"
        if (color) {
            switch (s.mark) {
                case "<" => line = "${ansiRed}${line}${ansiReset}"
                case ">" => line = "${ansiGreen}${line}${ansiReset}"
                case " " => line = "${ansiCyan}${line}${ansiReset}"
                case _ => {}
            }
        }
        for (c in "${line}\n".runes()) { b.append(c) }
    }
    String.fromRunes(b)
}

func diffStats(d: String): String {
    if (d == "") { return "(no changes)" }
    var add: Int32 = 0
    var del: Int32 = 0
    for (line in d.split("\n")) {
        if (line.startsWith("+") && !line.startsWith("+++")) {
            add++
        } else if (line.startsWith("-") && !line.startsWith("---")) {
            del++
        }
    }
    "(+${add} -${del})"
}

let ansiRed = "\u001b[31m"
let ansiGreen = "\u001b[32m"
let ansiCyan = "\u001b[36m"
let ansiReset = "\u001b[0m"

func stderrIsTTY(): Bool {
    match (os.stderr.stat()) {
        case Ok(fi) => fi.isCharDevice()
        Err(e) => false
    }
}

func previewBytes(b: Array<UInt8>): String {
    let s = String.fromUtf8(b)
    if (s == null) {
        return "<non-text output, ${b.size} bytes>\n"
    }
    s
}

func indent(s: String): String {
    if (s == "") { return "(no output)\n" }
    var b = ArrayList<Rune>()
    let trimmed = s.trimEnd("\n")
    for (line in trimmed.split("\n")) {
        for (c in "  ${line}\n".runes()) { b.append(c) }
    }
    String.fromRunes(b)
}
