// Cycle: agent main loop with rounds, stream view, and ledger.
package cpi.internal.cycle

import std.io.*
import std.json.*
import std.time.*
import std.collection.*

import cpi.internal.apperr.*
import cpi.internal.config.*
import cpi.internal.ctl.*
import cpi.internal.ir.*
import cpi.internal.proto.*
import cpi.internal.session.*
import cpi.internal.tools.*

public let MAX_ROUNDS = 10
public let STUB_NOTE = "[interrupted] call got no result"

public class StreamView {
    var region: String = ""
    var sawDelta: Bool = false

    func closeRegion() {
        if (region != "") {
            stderr.write("@T end\n".toUtf8())
            region = ""
        }
    }

    public func feed(f: Frame) {
        if (let fin <- f.final_) {
            closeRegion()
            if (!sawDelta && fin.text != "" && fin.calls.size > 0) {
                stderr.write("${fin.text}\n".toUtf8())
            }
        } else if (f.deltaKind == KIND_THINK || f.deltaKind == KIND_ANSWER) {
            if (region != f.deltaKind) {
                closeRegion()
                stderr.write("@T begin ${f.deltaKind}\n".toUtf8())
                region = f.deltaKind
            }
            stderr.write(f.deltaText.toUtf8())
            sawDelta = true
        }
    }

    public func callLine(c: Call) {
        closeRegion()
        let json = JsonParser.serialize(CallLineData(c.id, c.name, c.args)).getOrThrow()
        stderr.write("@C ${json}\n".toUtf8())
    }

    public func breakLine(cause: String) {
        closeRegion()
        let json = JsonParser.serialize(BreakLineData(cause)).getOrThrow()
        stderr.write("@K ${json}\n".toUtf8())
    }
}

class CallLineData {
    public var id: String
    public var name: String
    public var args: String
    init(id: String, name: String, args: String) {
        this.id = id
        this.name = name
        this.args = args
    }
}

class BreakLineData {
    public var cause: String
    init(cause: String) { this.cause = cause }
}

public func applyOutcome(msgs: ArrayList<Msg>, oc: ChatOutcome): (ArrayList<Msg>, Int32) {
    var r = oc.reply.getOrThrow()
    var n: Int32 = 0
    if (oc.partial) {
        var kept = ArrayList<Call>()
        var dropped: Int32 = 0
        for (c in r.calls) {
            if (isValidJson(c.args)) {
                kept.append(c)
            } else {
                dropped++
            }
        }
        r = Reply(r.text, kept)
        if (r.text == "" && kept.size == 0 && dropped > 0) {
            return (msgs, dropped)
        }
        if (dropped > 0) {
            n += dropped
            var newMsgs = ArrayList<Msg>(msgs)
            newMsgs.append(Msg("tool", STUB_NOTE, ArrayList<Call>(), "(interrupted)"))
            return (newMsgs, n)
        }
    }
    var result = ArrayList<Msg>(msgs)
    result.append(Msg("assistant", r.text, r.calls, ""))
    (result, n)
}

func isValidJson(s: String): Bool {
    match (JsonParser.parse(s)) {
        case Ok(_) => true
        Err(e) => false
    }
}

func isQuotaCut(fr: String): Bool {
    fr == "length" || fr == "max_tokens" || fr == "incomplete"
}

func truncateOneLine(s: String): String {
    var first = s
    if (let idx <- s.indexOf("\n")) {
        first = s.substring(0, idx)
    }
    let runes = first.toRuneArray()
    if (runes.size > 160) {
        String.fromRunes(runes.slice(0, 160))
    } else {
        first
    }
}

func toolRef(argsJSON: String): ?ToolRef {
    var cmd = ""
    let json = match (JsonParser.parse(argsJSON)) {
        case Ok(j) => j
        Err(e) => return None
    }
    if (let obj: JsonObject <- json) {
        if (let cv <- obj.get("cmd")) {
            if (let cs: JsonString <- cv) { cmd = cs.value }
        }
    }
    let paths = tools.registryPaths()
    for (p in paths) {
        if (cmd.contains(p)) {
            var ref = ToolRef(p, "", "")
            let full = Path(homeAgentTools()).join(p).toString()
            match (fs.stat(full)) {
                case Ok(fi) =>
                    ref.mtime = fi.modifiedAt.toRFC3339()
                    match (fs.readToString(full)) {
                        case Ok(content) =>
                            let hash = Sha256.digest(content.toUtf8())
                            ref.hash = "sha256:${hash.toHex().substring(0, 16)}"
                        Err(e) => {}
                    }
                Err(e) => {}
            }
            return ref
        }
    }
    None
}

func homeAgentTools(): String {
    match (os.homeDir()) {
        case Some(h) => Path(h).join("agent-tools").toString()
        case None => ""
    }
}

func attributionOrEmpty(c: Call): String {
    if (c.name != "bash") { return "" }
    var cmd = ""
    let json = match (JsonParser.parse(c.args)) {
        case Ok(j) => j
        Err(e) => return ""
    }
    if (let obj: JsonObject <- json) {
        if (let cv <- obj.get("cmd")) {
            if (let cs: JsonString <- cv) { cmd = cs.value }
        }
    }
    obs.attribution(cmd, tools.registryPaths())
}

func run(ctx: Context, chatFn: (Context, ArrayList<Msg>, Settings, ArrayList<ToolDecl>, FrameSink) -> ?ChatOutcome,
    task: String, st: Settings, sess: ?Session, ctrl: ?Control): ?(String, Exception) {
    let start = DateTime.now()
    let runNo = match (sess) {
        case Some(s) => s.beginRun(task)
        case None => 0
    }
    var msgs = ArrayList<Msg>([Msg("user", task, ArrayList<Call>(), "")])
    var roundsUsed: Int32 = 0

    let finalize = { _: Unit =>
        match (ctrl) {
            case Some(c) =>
                c.phase(PHASE_DONE)
                c.phase(PHASE_WAIT)
                c.waitGone()
                c.phase(PHASE_END)
            case None => {}
        }
    }

    for (round in 1..=MAX_ROUNDS) {
        match (ctrl) {
            case Some(c) =>
                if (c.isGone()) {
                    match (sess) {
                        case Some(s) => s.end(runNo, 0, roundsUsed, DateTime.now().millisecondsSince(start), "")
                        case None => {}
                    }
                    finalize()
                    return ("", Exception(""))
                }
            case None => {}
        }
        let view = StreamView()
        match (ctrl) {
            case Some(c) => c.phase(PHASE_MODEL)
            case None => {}
        }
        let outcome = match (chatFn(ctx, msgs, st, tools.declarations(), { f: Frame => view.feed(f) })) {
            case Some(o) => o
            case None => return ("", Exception("chat failed"))
        }

        if (let oc <- outcome.reply) {
            if (oc.partial) {
                view.breakLine(oc.cause)
                match (sess) {
                    case Some(s) =>
                        s.break_(runNo, round, oc.cause, Int64(oc.raw.size))
                        s.llm(runNo, round, oc.raw, oc.rawCut)
                    case None => {}
                }
            } else {
                match (sess) {
                    case Some(s) => s.llm(runNo, round, oc.raw, oc.rawCut)
                    case None => {}
                }
            }
            var stubs: Int32 = 0
            (msgs, stubs) = applyOutcome(msgs, oc)
            for (i in 1..=stubs) {
                match (sess) {
                    case Some(s) => s.patch(runNo, round, i, STUB_NOTE)
                    case None => {}
                }
            }
            roundsUsed = round
        }

        match (outcome) {
            case Some(oc) =>
                if (oc.partial && oc.cause == CAUSE_INTERRUPTED) {
                    match (sess) {
                        case Some(s) =>
                            s.cancel(runNo, roundsUsed)
                            s.end(runNo, 0, roundsUsed, DateTime.now().millisecondsSince(start), oc.reply.getOrThrow().text)
                        case None => {}
                    }
                    finalize()
                    return (oc.reply.getOrThrow().text, Exception(""))
                }
            case None => {}
        }

        let r = outcome.reply.getOrThrow()
        if (r.calls.size == 0) {
            var ans = r.text
            if (isQuotaCut(outcome.finishReason)) {
                view.breakLine("max_tokens")
                stderr.write("Warning: answer truncated by model output quota (finish_reason=${outcome.finishReason})\n".toUtf8())
                match (sess) {
                    case Some(s) => s.note(runNo, "Answer truncated by max_tokens (finish_reason=${outcome.finishReason})")
                    case None => {}
                }
            }
            match (sess) {
                case Some(s) => s.end(runNo, 0, roundsUsed, DateTime.now().millisecondsSince(start), ans)
                case None => {}
            }
            finalize()
            return (ans, Exception(""))
        }
        for (seq in 0..r.calls.size) {
            let c = r.calls[seq]
            view.callLine(c)
            match (sess) {
                case Some(s) => s.call(runNo, round, Int32(seq) + 1, DateTime.now(), c.name, c.args, toolRef(c.args))
                case None => {}
            }
            let resultStart = DateTime.now()
            match (ctrl) {
                case Some(ct) => ct.phase(PHASE_TOOL)
                case None => {}
            }
            let (result, display, derr) = match (tools.dispatch(ctx, c, st)) {
                case Some((res, disp, err)) => (res, disp, err)
                case None => ("", "", Exception("dispatch failed"))
            }
            stderr.write("@R begin\n".toUtf8())
            stderr.write(display.toUtf8())
            stderr.write("@R end\n".toUtf8())

            var exitCode: Int32 = 0
            var hint = ""
            if (derr.message != "") {
                exitCode = 1
                hint = truncateOneLine(derr.message)
            }
            match (sess) {
                case Some(s) => s.result(runNo, round, Int32(seq) + 1, resultStart, attributionOrEmpty(c),
                    exitCode, DateTime.now().millisecondsSince(resultStart), hint, result, "")
                case None => {}
            }

            var finalResult = result
            if (derr.message != "") {
                finalResult = "Execution error: ${derr.message}\nExisting output:\n${result}"
            }
            msgs.append(Msg("tool", finalResult, ArrayList<Call>(), c.id))

            if (ctx.isCancelled()) {
                match (sess) {
                    case Some(s) =>
                        s.cancel(runNo, round)
                        s.end(runNo, 0, round, DateTime.now().millisecondsSince(start), "")
                    case None => {}
                }
                finalize()
                return ("", Exception(""))
            }
        }
        match (ctrl) {
            case Some(c) =>
                if (c.isGone()) {
                    match (sess) {
                        case Some(s) => s.end(runNo, 0, roundsUsed, DateTime.now().millisecondsSince(start), "")
                        case None => {}
                    }
                    finalize()
                    return ("", Exception(""))
                }
            case None => {}
        }
    }
    match (sess) {
        case Some(s) => s.end(runNo, 2, MAX_ROUNDS, DateTime.now().millisecondsSince(start), "")
        case None => {}
    }
    finalize()
    ("", CodedError(2, "Exceeded ${MAX_ROUNDS} rounds without final answer"))
}

public func runMain(ctx: Context, sess: ?Session, task: String, st: Settings, ctrl: ?Control): ?(String, Exception) {
    run(ctx, proto.chat, task, st, sess, ctrl)
}
