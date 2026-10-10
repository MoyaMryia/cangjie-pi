// Session: on-disk ledger for agent runs.
package cpi.internal.session

import std.io.*
import std.json.*
import std.os.*
import std.fs.*
import std.time.*
import std.sync.*
import std.crypto.*

import cpi.internal.apperr.*

public let DIR_NAME = ".cpi"
public let DUMP_DIR_NAME = "dumps"
public let STREAM_CAP = 8192
public let WIRE_CAP = 1048576
public let HEAD_V = 1

public class Head {
    public var t: String
    public var v: Int32
    public var model: String
    public var protocol: String
    public var apiBase: String
    public var maxTokens: Int32
    public var cwd: String
    public var startedAt: String

    init(t: String, v: Int32, model: String, protocol: String, apiBase: String,
        maxTokens: Int32, cwd: String, startedAt: String) {
        this.t = t
        this.v = v
        this.model = model
        this.protocol = protocol
        this.apiBase = apiBase
        this.maxTokens = maxTokens
        this.cwd = cwd
        this.startedAt = startedAt
    }
}

public class UserRow {
    public var t: String
    public var run: Int32
    public var text: String

    init(t: String, run: Int32, text: String) {
        this.t = t
        this.run = run
        this.text = text
    }
}

public class LLMRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var wire: String
    public var raw: Bool

    init(t: String, run: Int32, round: Int32, wire: String, raw: Bool) {
        this.t = t
        this.run = run
        this.round = round
        this.wire = wire
        this.raw = raw
    }
}

public class ToolRef {
    public var path: String
    public var mtime: String
    public var hash: String

    init(path: String, mtime: String, hash: String) {
        this.path = path
        this.mtime = mtime
        this.hash = hash
    }
}

public class CallRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var seq: Int32
    public var at: String
    public var name: String
    public var args: String
    public var toolRef: ?ToolRef

    init(t: String, run: Int32, round: Int32, seq: Int32, at: String, name: String,
        args: String, toolRef: ?ToolRef) {
        this.t = t
        this.run = run
        this.round = round
        this.seq = seq
        this.at = at
        this.name = name
        this.args = args
        this.toolRef = toolRef
    }
}

public class Truncated {
    public var bytesTotal: Int32
    public var full: String

    init(bytesTotal: Int32, full: String) {
        this.bytesTotal = bytesTotal
        this.full = full
    }
}

public class ResultRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var seq: Int32
    public var at: String
    public var toolID: String
    public var exit: Int32
    public var durMS: Int64
    public var hint: String
    public var stdout: String
    public var stderr: String
    public var outFull: ?Truncated
    public var errFull: ?Truncated

    init(t: String, run: Int32, round: Int32, seq: Int32, at: String, toolID: String,
        exit: Int32, durMS: Int64, hint: String, stdout: String, stderr: String,
        outFull: ?Truncated, errFull: ?Truncated) {
        this.t = t
        this.run = run
        this.round = round
        this.seq = seq
        this.at = at
        this.toolID = toolID
        this.exit = exit
        this.durMS = durMS
        this.hint = hint
        this.stdout = stdout
        this.stderr = stderr
        this.outFull = outFull
        this.errFull = errFull
    }
}

public class VerdictRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var seq: Int32
    public var by: String
    public var ok: Bool

    init(t: String, run: Int32, round: Int32, seq: Int32, by: String, ok: Bool) {
        this.t = t
        this.run = run
        this.round = round
        this.seq = seq
        this.by = by
        this.ok = ok
    }
}

public class BreakRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var cause: String
    public var atWireBytes: Int64

    init(t: String, run: Int32, round: Int32, cause: String, atWireBytes: Int64) {
        this.t = t
        this.run = run
        this.round = round
        this.cause = cause
        this.atWireBytes = atWireBytes
    }
}

public class PatchRow {
    public var t: String
    public var run: Int32
    public var round: Int32
    public var seq: Int32
    public var kind: String
    public var note: String

    init(t: String, run: Int32, round: Int32, seq: Int32, kind: String, note: String) {
        this.t = t
        this.run = run
        this.round = round
        this.seq = seq
        this.kind = kind
        this.note = note
    }
}

public class CancelRow {
    public var t: String
    public var run: Int32
    public var atEvent: Int32

    init(t: String, run: Int32, atEvent: Int32) {
        this.t = t
        this.run = run
        this.atEvent = atEvent
    }
}

public class FinalRef {
    public var line: Int32
    public var sha: String

    init(line: Int32, sha: String) {
        this.line = line
        this.sha = sha
    }
}

public class EndRow {
    public var t: String
    public var run: Int32
    public var exit: Int32
    public var finalRef: ?FinalRef
    public var rounds: Int32
    public var tookMS: Int64

    init(t: String, run: Int32, exit: Int32, finalRef: ?FinalRef, rounds: Int32, tookMS: Int64) {
        this.t = t
        this.run = run
        this.exit = exit
        this.finalRef = finalRef
        this.rounds = rounds
        this.tookMS = tookMS
    }
}

public class NoteRow {
    public var t: String
    public var run: Int32
    public var text: String

    init(t: String, run: Int32, text: String) {
        this.t = t
        this.run = run
        this.text = text
    }
}

public class Session {
    var path: String
    var dumps: String
    var f: ?File
    var lineNo: Int32 = 0
    var lastLLM: Int32 = 0
    var lastSHA: String = ""
    var run: Int32 = 0
    var mu = Mutex()

    init(path: String, dumps: String, f: File) {
        this.path = path
        this.dumps = dumps
        this.f = f
    }

    public func getPath(): String { path }
    public func getDumpsDir(): String { dumps }

    func write(v: Any): ?(Int32, Array<UInt8>) {
        match (f) {
            case Some(file) =>
                mu.lock()
                let json = match (JsonParser.serialize(v)) {
                    case Ok(s) => s
                    Err(e) =>
                        mu.unlock()
                        return None
                }
                let line = json + "\n"
                let bytes = line.toUtf8()
                match (file.write(bytes)) {
                    case Ok(n) =>
                        lineNo++
                        mu.unlock()
                        return (lineNo, bytes)
                    Err(e) =>
                        mu.unlock()
                        return None
                }
            case None => None
        }
    }

    public func beginRun(text: String): Int32 {
        mu.lock()
        run++
        let r = run
        mu.unlock()
        write(UserRow("user", r, text))
        r
    }

    public func getRun(): Int32 {
        mu.lock()
        let r = run
        mu.unlock()
        r
    }

    public func llm(run: Int32, round: Int32, wire: Array<UInt8>, truncated: Bool) {
        let row = LLMRow("llm", run, round, String.fromUtf8(wire), truncated)
        match (write(row)) {
            case Some((ln, bytes)) =>
                mu.lock()
                lastLLM = ln
                lastSHA = sha16(bytes)
                mu.unlock()
            case None => {}
        }
    }

    public func call(run: Int32, round: Int32, seq: Int32, at: DateTime, name: String,
        args: String, ref: ?ToolRef) {
        let atStr = at.toRFC3339()
        write(CallRow("call", run, round, seq, atStr, name, args, ref))
    }

    public func result(run: Int32, round: Int32, seq: Int32, at: DateTime, toolID: String,
        exitCode: Int32, durMS: Int64, hint: String, stdout: String, stderr: String) {
        let atStr = at.toRFC3339()
        var row = ResultRow("result", run, round, seq, atStr, toolID, exitCode, durMS, hint,
            stdout, stderr, None, None)
        let (outStr, outFull) = capStream(run, round, seq, "out", stdout)
        row.stdout = outStr
        row.outFull = outFull
        let (errStr, errFull) = capStream(run, round, seq, "err", stderr)
        row.stderr = errStr
        row.errFull = errFull
        write(row)
    }

    func capStream(run: Int32, round: Int32, seq: Int32, tag: String, content: String): (String, ?Truncated) {
        let total = content.byteLength()
        if (total <= STREAM_CAP) {
            return (content, None)
        }
        let name = "${dumps}/r${run}-${round}-${seq}.${tag}"
        match (fs.writeFile(name, content)) {
            case Ok(_) => return (content.substring(0, STREAM_CAP), Truncated(Int32(total), name))
            Err(e) => return (content.substring(0, STREAM_CAP), Truncated(Int32(total), "(overflow failed)"))
        }
    }

    public func verdict(run: Int32, round: Int32, seq: Int32, by: String, ok: Bool) {
        write(VerdictRow("verdict", run, round, seq, by, ok))
    }

    public func break_(run: Int32, round: Int32, cause: String, atWireBytes: Int64) {
        write(BreakRow("break", run, round, cause, atWireBytes))
    }

    public func patch(run: Int32, round: Int32, seq: Int32, note: String) {
        write(PatchRow("patch", run, round, seq, "stub", note))
    }

    public func cancel(run: Int32, atEvent: Int32) {
        write(CancelRow("cancel", run, atEvent))
    }

    public func end(run: Int32, exitCode: Int32, rounds: Int32, tookMS: Int64, finalText: String) {
        var row = EndRow("end", run, exitCode, None, rounds, tookMS)
        mu.lock()
        let llmLine = lastLLM
        let llmSHA = lastSHA
        mu.unlock()
        if (finalText != "" && llmLine > 0) {
            row.finalRef = FinalRef(llmLine, llmSHA)
        }
        write(row)
    }

    public func note(run: Int32, text: String) {
        write(NoteRow("note", run, text))
    }

    public func close() {
        match (f) {
            case Some(file) =>
                file.sync()
                file.close()
                f = None
            case None => {}
        }
    }
}

func sha16(b: Array<UInt8>): String {
    let hash = Sha256.digest(b)
    let hex = hash.toHex()
    hex.substring(0, 16)
}

func tsName(t: DateTime): String {
    t.format("YYYYMMDD-HHmmss")
}

func nowRFC3339(): String {
    DateTime.now().toRFC3339()
}

public func dir(cwd: String): String {
    Path(cwd).join(DIR_NAME).toString()
}

public func openOrCreate(cwd: String, model: String, protocol: String, apiBase: String,
    maxTokens: Int32): ?Session {
    if (model == "" || protocol == "" || apiBase == "" || maxTokens <= 0 || cwd == "") {
        return None
    }
    let d = dir(cwd)
    match (fs.createDirAll(d)) {
        case Ok(_) => {}
        Err(e) => return None
    }
    let now = DateTime.now()
    let dumps = Path(d).join(DUMP_DIR_NAME).join(tsName(now)).toString()
    match (fs.createDirAll(dumps)) {
        case Ok(_) => {}
        Err(e) => return None
    }

    let newest = newestSession(d)
    if (newest != "") {
        match (mountForAppend(newest, dumps)) {
            case Some(s) => return s
            Err(e) => {}
        }
    }

    let name = "session-${tsName(now)}.jsonl"
    let path = Path(d).join(name).toString()
    var f: ?File = None
    var i = 1
    while (true) {
        match (fs.createFile(path)) {
            case Ok(file) =>
                f = file
                break
            Err(e) =>
                if (e.message.contains("exist")) {
                    let altName = "session-${tsName(now)}-${i}.jsonl"
                    path = Path(d).join(altName).toString()
                    i++
                } else {
                    return None
                }
        }
    }
    let file = f.getOrThrow()
    let h = Head("head", HEAD_V, model, protocol, apiBase, maxTokens, cwd, nowRFC3339())
    let json = match (JsonParser.serialize(h)) {
        case Ok(s) => s
        Err(e) =>
            file.close()
            return None
    }
    let bytes = (json + "\n").toUtf8()
    match (file.write(bytes)) {
        case Ok(n) => {}
        Err(e) =>
            file.close()
            return None
    }
    Session(path, dumps, file)
}

func newestSession(d: String): String {
    match (fs.readDir(d)) {
        case Ok(entries) =>
            var names = ArrayList<String>()
            for (e in entries) {
                if (!e.isDir() && e.name.startsWith("session-") && e.name.endsWith(".jsonl")) {
                    names.append(e.name)
                }
            }
            if (names.size == 0) {
                return ""
            }
            names.sort()
            Path(d).join(names[names.size - 1]).toString()
        Err(e) => ""
    }
}

func isEmptyShell(path: String): Bool {
    let raw = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return false
    }
    for (line in raw.split("\n")) {
        if (line.contains("\"t\":\"user\"")) {
            return false
        }
    }
    raw.byteLength() > 0
}

func mountForAppend(path: String, dumps: String): ?Session {
    let raw = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }
    let lines = raw.split("\n")
    if (lines.size == 0 || !lines[0].startsWith("{\"t\":\"head\"")) {
        return None
    }
    let h = match (JsonParser.parse(lines[0])) {
        case Ok(j) => j
        Err(e) => return None
    }
    if (let obj: JsonObject <- h) {
        var v: Int32 = 0
        var model = ""
        var protocol = ""
        var apiBase = ""
        var maxTokens: Int32 = 0
        var cwd = ""
        var startedAt = ""
        if (let vv <- obj.get("v")) {
            if (let vi: JsonInt <- vv) { v = Int32(vi.value) }
        }
        if (let mv <- obj.get("model")) {
            if (let ms: JsonString <- mv) { model = ms.value }
        }
        if (let pv <- obj.get("protocol")) {
            if (let ps: JsonString <- pv) { protocol = ps.value }
        }
        if (let av <- obj.get("apiBase")) {
            if (let as_: JsonString <- av) { apiBase = as_.value }
        }
        if (let tv <- obj.get("maxTokens")) {
            if (let ti: JsonInt <- tv) { maxTokens = Int32(ti.value) }
        }
        if (let cv <- obj.get("cwd")) {
            if (let cs: JsonString <- cv) { cwd = cs.value }
        }
        if (let sv <- obj.get("startedAt")) {
            if (let ss: JsonString <- sv) { startedAt = ss.value }
        }
        if (v != HEAD_V || model == "" || protocol == "" || apiBase == "" ||
            maxTokens <= 0 || cwd == "" || startedAt == "") {
            return None
        }
    }
    if (!isEmptyShell(path)) {
        return None
    }
    match (fs.openFile(path, "a")) {
        case Ok(f) => Session(path, dumps, f)
        Err(e) => None
    }
}

public func line(path: String, n: Int32): ?Array<UInt8> {
    let raw = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }
    let lines = raw.split("\n")
    if (n < 1 || n > Int32(lines.size)) {
        return None
    }
    lines[n - 1].toUtf8()
}

public func verifyFinalRef(path: String, ref: FinalRef): ?Exception {
    let b = match (line(path, ref.line)) {
        case Some(b) => b
        Err(e) => return e
    }
    if (sha16(b) != ref.sha) {
        return Exception("fingerprint mismatch at line ${ref.line}")
    }
    None
}

public func load(path: String): ?(Head, ArrayList<String>) {
    let raw = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }
    let lines = raw.split("\n")
    if (lines.size == 0 || !lines[0].startsWith("{\"t\":\"head\"")) {
        return None
    }
    let h = match (JsonParser.parse(lines[0])) {
        case Ok(j) => j
        Err(e) => return None
    }
    var head = Head("", 0, "", "", "", 0, "", "")
    if (let obj: JsonObject <- h) {
        if (let vv <- obj.get("v")) {
            if (let vi: JsonInt <- vv) { head.v = Int32(vi.value) }
        }
        if (let mv <- obj.get("model")) {
            if (let ms: JsonString <- mv) { head.model = ms.value }
        }
        if (let pv <- obj.get("protocol")) {
            if (let ps: JsonString <- pv) { head.protocol = ps.value }
        }
        if (let av <- obj.get("apiBase")) {
            if (let as_: JsonString <- av) { head.apiBase = as_.value }
        }
        if (let tv <- obj.get("maxTokens")) {
            if (let ti: JsonInt <- tv) { head.maxTokens = Int32(ti.value) }
        }
        if (let cv <- obj.get("cwd")) {
            if (let cs: JsonString <- cv) { head.cwd = cs.value }
        }
        if (let sv <- obj.get("startedAt")) {
            if (let ss: JsonString <- sv) { head.startedAt = ss.value }
        }
    }
    let lineList = ArrayList<String>()
    for (l in lines) {
        lineList.append(l)
    }
    (head, lineList)
}

public func isEmptyShellPublic(path: String): Bool {
    isEmptyShell(path)
}
