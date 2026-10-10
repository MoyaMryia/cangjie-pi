// Search: find_tools registry searcher.
package cpi.internal.tools

import std.json.*
import std.collection.*

import cpi.internal.obs.*

class ParamRow {
    public var name: String
    public var description: String

    init(name: String, description: String) {
        this.name = name
        this.description = description
    }
}

func kindLabel(e: RegistryEntry): String {
    if (e.kind == "") { "tool" } else { e.kind }
}

func usageBlock(e: RegistryEntry): String {
    var b = ""
    var rows = ArrayList<ParamRow>()
    var req = HashSet<String>()
    if (e.params != "") {
        let json = match (JsonParser.parse(e.params)) {
            case Ok(j) => j
            Err(e2) => JsonNull()
        }
        if (let obj: JsonObject <- json) {
            if (let props <- obj.get("properties")) {
                if (let propsObj: JsonObject <- props) {
                    for ((name, p) in propsObj) {
                        var desc = ""
                        if (let pv <- p) {
                            if (let pObj: JsonObject <- pv) {
                                if (let dv <- pObj.get("description")) {
                                    if (let ds: JsonString <- dv) { desc = ds.value }
                                }
                            }
                        }
                        rows.append(ParamRow(name, desc))
                    }
                }
            }
            if (let reqArr <- obj.get("required")) {
                if (let arr: JsonArray <- reqArr) {
                    for (r in arr) {
                        if (let rs: JsonString <- r) {
                            req.put(rs.value)
                        }
                    }
                }
            }
        }
    }
    rows.sortBy { a: ParamRow, b: ParamRow =>
        let ra = req.contains(a.name)
        let rb = req.contains(b.name)
        if (ra != rb) {
            if (ra) { return Ordering.LT } else { return Ordering.GT }
        }
        a.name.compare(b.name)
    }
    b += "Usage:\n  ~/agent-tools/${e.path}"
    for (r in rows) {
        var desc = r.description
        if (desc == "") { desc = r.name }
        if (req.contains(r.name)) {
            b += " ${r.name} <${desc}>"
        } else {
            b += " [${r.name} <${desc}>]"
        }
    }
    b += "\n"
    if (rows.size > 0) {
        b += "Params:\n"
        for (r in rows) {
            var mark = ""
            if (req.contains(r.name)) { mark = " (required)" }
            var desc = r.description
            if (desc == "") { desc = "(no description)" }
            b += "  ${r.name}  ${desc}${mark}\n"
        }
    }
    b
}

func searchRegistry(queries: ArrayList<String>): ?(String, Int32, Exception) {
    if (queries.size == 0) {
        return ("", 0, Exception("missing search keywords"))
    }
    let registry = match (loadRegistry()) {
        case Ok(r) => r
        Err(e) => return ("", 0, Exception("read tool pool registry: ${e.message}"))
    }
    class Hit {
        let entry: RegistryEntry
        let score: Int32
        init(entry: RegistryEntry, score: Int32) {
            this.entry = entry
            this.score = score
        }
    }
    var hits = ArrayList<Hit>()
    for (t in registry) {
        var hay = "${t.name} ${t.description} ${t.domain} ${kindLabel(t)} ${t.tags.join(" ")}".toLower()
        var score: Int32 = 0
        for (q in queries) {
            if (hay.contains(q.toLower())) {
                score++
            }
        }
        if (score > 0) {
            hits.append(Hit(t, score))
        }
    }
    hits.sortBy { a: Hit, b: Hit =>
        if (a.score != b.score) {
            b.score.compare(a.score)
        } else {
            a.entry.name.compare(b.entry.name)
        }
    }
    if (hits.size == 0) {
        return ("(No match in tool pool. Continue with decision tree:\n 1. Combine: try different keywords, can bash pipeline achieve it?\n 2. Design: is this capability worth long-term? -> tools/add_tool.py\n 3. Ad-hoc: one-time need -> use bash directly)", 0, Exception(""))
    }
    var cands = ArrayList<obs.CandidateRow>()
    for (i in 0..hits.size) {
        let h = hits[i]
        var tid = obs.toolIDFromPath(h.entry.path)
        if (tid == "") { tid = "unknown" }
        cands.append(obs.CandidateRow(tid, h.score, Int32(i) + 1))
    }
    obs.recordSearch("", queries, cands)
    var b = ""
    for (h in hits) {
        b += "■ ${h.entry.name}  [${h.entry.domain}] <${kindLabel(h.entry)}>\n"
        b += usageBlock(h.entry)
        b += "   Description: ${h.entry.description}\n"
        b += "   Tags: ${h.entry.tags.join(" ")}\n\n"
    }
    (b, Int32(hits.size), Exception(""))
}
