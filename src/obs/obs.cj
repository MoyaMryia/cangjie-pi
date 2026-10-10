// Obs: observation logging to toolpool.db (agent-tools repo).
package cpi.internal.obs

import std.io.*
import std.json.*
import std.os.*
import std.fs.*
import std.time.*
import std.sync.*
import std.collection.*

var dbPath: String = ""
var dbOpened = false
var dbMu = Mutex()

func init() {
    match (os.homeDir()) {
        case Some(h) => dbPath = Path(h).join("agent-tools").join("state").join("toolpool.db").toString()
        case None => {}
    }
}

public func setDBPath(p: String) {
    dbMu.lock()
    dbPath = p
    dbMu.unlock()
}

public func open(): Bool {
    dbMu.lock()
    if (dbOpened) {
        dbMu.unlock()
        return true
    }
    dbMu.unlock()
    false
}

func write(fn: () -> Unit): Unit {
    if (!open()) { return }
    dbMu.lock()
    fn()
    dbMu.unlock()
}

func nowUTC(): String {
    DateTime.now().toRFC3339()
}

public class CandidateRow {
    public var toolID: String
    public var matches: Int32
    public var rank: Int32

    init(toolID: String, matches: Int32, rank: Int32) {
        this.toolID = toolID
        this.matches = matches
        this.rank = rank
    }
}

public func recordSearch(toolID: String, query: ArrayList<String>, candidates: ArrayList<CandidateRow>): Unit {
    if (candidates.size == 0) { return }
    let sid = "srch_${DateTime.now().millisecondsSinceEpoch()}"
    write(() => {})
}

public func recordCall(toolID: String, started: DateTime, finished: DateTime, outcome: String,
    timeout: Bool, errorHint: String, durationMS: Int64): Unit {
    write(() => {})
}

public func attribution(cmd: String, paths: ArrayList<String>): String {
    let normCmd = " ${normalizeInvocation(cmd)} "
    var best = ""
    var bestID = ""
    for (p in paths) {
        let normP = normalizeInvocation(p)
        if (normP == "") { continue }
        if (normCmd.contains(" ${normP}")) {
            if (normP.byteLength() > best.byteLength()) {
                best = normP
                bestID = toolIDFromPath(p)
            }
        }
    }
    bestID
}

func normalizeInvocation(s: String): String {
    var result = s.trim()
    result = result.replace("~/agent-tools/", "")
    result = result.replace("./", "")
    result = result.replace("\\", "/")
    result.split("\\s+").join(" ")
}

public func toolIDFromPath(p: String): String {
    var path = p.trim().trimEnd("/")
    path = path.trimStart("~/agent-tools/")
    path = path.trimStart("./")
    let fields = path.split("\\s+")
    if (fields.size == 0) { return "" }
    var rel = fields[0]
    if (rel.startsWith("tools/")) {
        rel = rel.substring(6)
    }
    if (!rel.endsWith(".py")) { return "" }
    var parts = rel.split("/")
    var segs = ArrayList<String>()
    for (s in parts) {
        var seg = s
        if (seg.endsWith(".py")) {
            seg = seg.substring(0, seg.byteLength() - 3)
        }
        if (seg != "") {
            segs.append(seg)
        }
    }
    if (segs.size == 0) { return "" }
    var core = ArrayList<String>()
    for (s in segs) {
        if (core.size > 0 && s == core[0]) { continue }
        core.append(s)
    }
    var result = core.join("/")
    if (fields.size > 1) {
        result += "/${fields[1]}"
    }
    result
}
