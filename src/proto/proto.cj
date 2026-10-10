// Proto: protocol adapters for OpenAI Chat, Anthropic Messages, OpenAI Responses.
package cpi.internal.proto

import std.io.*
import std.json.*
import std.net.*
import std.time.*
import std.collection.*

import cpi.internal.apperr.*
import cpi.internal.config.*
import cpi.internal.ir.*
import cpi.internal.wire.*

public func chat(ctx: Context, messages: ArrayList<Msg>, st: Settings,
    decls: ArrayList<ToolDecl>, sink: FrameSink): ?ChatOutcome {
    let keyRaw = match (fs.readToString(".zen_key")) {
        case Ok(c) => c
        Err(e) => return CodedError(66, "read .zen_key: ${e.message}")
    }
    let key = keyRaw.trim()

    var msgs = messages
    if (msgs.size > 0 && msgs[0].role != "system") {
        let content = config.loadSystemPrompt()
        if (content != "") {
            let sysMsg = ArrayList<Msg>()
            sysMsg.append(Msg("system", content, ArrayList<Call>(), ""))
            for (m in messages) {
                sysMsg.append(m)
            }
            msgs = sysMsg
        }
    }

    var body: Array<UInt8>
    switch (st.protocol) {
        case PROTO_OPENAI_CHAT =>
            match (buildOpenAIChat(msgs, st, decls)) {
                case Ok(b) => body = b
                Err(e) => return e
            }
        case PROTO_ANTHROPIC_MSGS =>
            match (buildAnthropic(msgs, st, decls)) {
                case Ok(b) => body = b
                Err(e) => return e
            }
        case PROTO_OPENAI_RESPONSES =>
            match (buildResponses(msgs, st, decls)) {
                case Ok(b) => body = b
                Err(e) => return e
            }
        case _ => return CodedError(78, "unknown protocol: ${st.protocol}")
    }

    let url = endpointFor(st.protocol, st.apiBase)
    let req = match (HttpClient.post(url, body)) {
        case Ok(r) => r
        Err(e) => return CodedError(69, "request failed: ${e.message}")
    }

    if (req.statusCode == 401 || req.statusCode == 403) {
        return CodedError(77, "credential rejected (HTTP ${req.statusCode})")
    }
    if (req.statusCode < 200 || req.statusCode >= 300) {
        return CodedError(69, "upstream unavailable (HTTP ${req.statusCode})")
    }

    if (!st.stream) {
        let raw = match (wire.readAll(req.body)) {
            case Some(b) => b
            None => return CodedError(69, "read response body failed")
        }
        let (r, fr, perr) = parseWhole(st.protocol, raw)
        match (perr) {
            case Some(e) => return e
            case None => {}
        }
        sink(Frame("", "", r, fr))
        return ChatOutcome(r, false, "", raw, false, fr)
    }
    chatStream(ctx, req.body, st, sink)
}

func endpointFor(protocol: String, base: String): String {
    let b = base.trimEnd("/")
    switch (protocol) {
        case PROTO_ANTHROPIC_MSGS => "${b}/v1/messages"
        case PROTO_OPENAI_RESPONSES => "${b}/responses"
        case _ => "${b}/chat/completions"
    }
}

func parseWhole(protocol: String, raw: Array<UInt8>): (?Reply, String, ?CodedError) {
    var frames = ArrayList<Frame>()
    var fr = ""
    let sink = { f: Frame =>
        frames.append(f)
        if (let fin <- f.final_) {
            if (f.finishReason != "") {
                fr = f.finishReason
            }
        }
    }
    var err: ?CodedError = None
    switch (protocol) {
        case PROTO_ANTHROPIC_MSGS =>
            match (parseAnthropic(raw, sink)) {
                case Ok(_) => {}
                Err(e) => err = e
            }
        case PROTO_OPENAI_RESPONSES =>
            match (parseResponses(raw, sink)) {
                case Ok(_) => {}
                Err(e) => err = e
            }
        case _ =>
            match (parseOpenAIChat(raw, sink)) {
                case Ok(_) => {}
                Err(e) => err = e
            }
    }
    match (err) {
        case Some(e) => return (None, "", e)
        case None => {}
    }
    for (i in frames.size - 1 .. 0 : -1) {
        if (let fin <- frames[i].final_) {
            return (fin, fr, None)
        }
    }
    (None, "", CodedError(65, "no final frame"))
}

class LimitedCapture {
    var buf = ArrayList<UInt8>()
    let cap: Int32
    var cut: Bool = false

    init(cap: Int32) { this.cap = cap }

    public func write(p: Array<UInt8>): Unit {
        if (buf.size < cap) {
            let room = cap - buf.size
            if (p.size <= room) {
                for (b in p) { buf.append(b) }
            } else {
                for (i in 0..room) { buf.append(p[i]) }
                cut = true
            }
        } else if (p.size > 0) {
            cut = true
        }
    }

    public func getBytes(): Array<UInt8> { buf.toArray() }
    public func isCut(): Bool { cut }
}

let WIRE_CAP_BYTES = 1048576

func chatStream(ctx: Context, rd: InputStream, st: Settings, sink: FrameSink): ?ChatOutcome {
    let tm = StreamTimer()
    let cap1 = LimitedCapture(WIRE_CAP_BYTES)

    var r: ?Reply = None
    var completed = false
    var fr = ""
    var serr: ?CodedError = None

    switch (st.protocol) {
        case PROTO_ANTHROPIC_MSGS =>
            match (streamAnthropic(rd, sink, tm)) {
                case Ok((reply, comp, reason, e)) =>
                    r = reply
                    completed = comp
                    fr = reason
                    serr = e
                Err(e) => serr = e
            }
        case PROTO_OPENAI_RESPONSES =>
            match (streamResponses(rd, sink, tm)) {
                case Ok((reply, comp, reason, e)) =>
                    r = reply
                    completed = comp
                    fr = reason
                    serr = e
                Err(e) => serr = e
            }
        case _ =>
            match (streamOpenAIChat(rd, sink, tm)) {
                case Ok((reply, comp, reason, e)) =>
                    r = reply
                    completed = comp
                    fr = reason
                    serr = e
                Err(e) => serr = e
            }
    }

    let out = ChatOutcome(r, false, "", cap1.getBytes(), cap1.isCut(), fr)
    let interrupted = ctx.isCancelled()

    match (serr) {
        case Some(e) =>
            if (r.isNone() || completed) {
                if (interrupted) {
                    return CodedError(69, "request interrupted by user")
                }
                return e
            }
            out.reply = r
            out.partial = true
            if (interrupted) {
                out.cause = CAUSE_INTERRUPTED
            } else {
                out.cause = CAUSE_BROKEN
            }
            return out
        case None => {}
    }
    out.reply = r
    sink(Frame("", "", r, ""))
    None
}

// ---------- OpenAI Chat ----------

class ChatRequest {
    public var model: String
    public var messages: ArrayList<WireMsg>
    public var tools: ArrayList<ToolSpecWire>
    public var maxTokens: Int32
    public var stream: Bool

    init(model: String, messages: ArrayList<WireMsg>, tools: ArrayList<ToolSpecWire>,
        maxTokens: Int32, stream: Bool) {
        this.model = model
        this.messages = messages
        this.tools = tools
        this.maxTokens = maxTokens
        this.stream = stream
    }
}

class ToolSpecWire {
    public var type_: String
    public var function: FunctionSpec

    init(type_: String, function: FunctionSpec) {
        this.type_ = type_
        this.function = function
    }
}

class FunctionSpec {
    public var name: String
    public var description: String
    public var parameters: HashMap<String, Any>

    init(name: String, description: String, parameters: HashMap<String, Any>) {
        this.name = name
        this.description = description
        this.parameters = parameters
    }
}

class WireMsg {
    public var role: String
    public var content: String
    public var toolCalls: ArrayList<WireCall>
    public var toolCallID: String

    init(role: String, content: String, toolCalls: ArrayList<WireCall>, toolCallID: String) {
        this.role = role
        this.content = content
        this.toolCalls = toolCalls
        this.toolCallID = toolCallID
    }
}

class WireCall {
    public var id: String
    public var type_: String
    public var function: CallFunction

    init(id: String, type_: String, function: CallFunction) {
        this.id = id
        this.type_ = type_
        this.function = function
    }
}

class CallFunction {
    public var name: String
    public var arguments: String

    init(name: String, arguments: String) {
        this.name = name
        this.arguments = arguments
    }
}

func buildOpenAIChat(messages: ArrayList<Msg>, st: Settings,
    decls: ArrayList<ToolDecl>): ?Array<UInt8> {
    var msgs = ArrayList<WireMsg>()
    for (m in messages) {
        var calls = ArrayList<WireCall>()
        for (c in m.calls) {
            calls.append(WireCall(c.id, "function", CallFunction(c.name, c.args)))
        }
        msgs.append(WireMsg(m.role, m.text, calls, m.callID))
    }
    let tools = openAIToolSpecs(decls)
    let req = ChatRequest(st.model, msgs, tools, st.maxTokens, st.stream)
    match (JsonParser.serialize(req)) {
        case Ok(s) => s.toUtf8()
        Err(e) => CodedError(65, "serialize request: ${e.message}")
    }
}

func parseOpenAIChat(raw: Array<UInt8>, sink: FrameSink): ?CodedError {
    let str = String.fromUtf8(raw)
    let json = match (JsonParser.parse(str)) {
        case Ok(j) => j
        Err(e) => return CodedError(65, "parse response: ${e.message}")
    }
    if (let obj: JsonObject <- json) {
        if (let err <- obj.get("error")) {
            if (let errObj: JsonObject <- err) {
                if (let msg <- errObj.get("message")) {
                    if (let ms: JsonString <- msg) {
                        if (ms.value != "") {
                            return CodedError(65, "API error: ${ms.value}")
                        }
                    }
                }
            }
        }
        if (let choices <- obj.get("choices")) {
            if (let arr: JsonArray <- choices) {
                if (arr.size > 0) {
                    if (let choice: JsonObject <- arr[0]) {
                        var content = ""
                        var finishReason = ""
                        var calls = ArrayList<Call>()
                        if (let msg <- choice.get("message")) {
                            if (let msgObj: JsonObject <- msg) {
                                if (let cv <- msgObj.get("content")) {
                                    if (let cs: JsonString <- cv) { content = cs.value }
                                }
                                if (let tc <- msgObj.get("tool_calls")) {
                                    if (let tcArr: JsonArray <- tc) {
                                        for (t in tcArr) {
                                            if (let tcObj: JsonObject <- t) {
                                                var id = ""
                                                var name = ""
                                                var args = ""
                                                if (let idv <- tcObj.get("id")) {
                                                    if (let ids: JsonString <- idv) { id = ids.value }
                                                }
                                                if (let fv <- tcObj.get("function")) {
                                                    if (let fObj: JsonObject <- fv) {
                                                        if (let nv <- fObj.get("name")) {
                                                            if (let ns: JsonString <- nv) { name = ns.value }
                                                        }
                                                        if (let av <- fObj.get("arguments")) {
                                                            if (let as_: JsonString <- av) { args = as_.value }
                                                        }
                                                    }
                                                }
                                                calls.append(Call(id, name, args))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (let fr <- choice.get("finish_reason")) {
                            if (let frs: JsonString <- fr) { finishReason = frs.value }
                        }
                        sink(Frame("", "", Reply(content, calls), finishReason))
                        return None
                    }
                }
            }
        }
    }
    CodedError(65, "no choices in response")
}

class SSECallAcc {
    var id: String = ""
    var name: String = ""
    var args: ArrayList<Rune> = ArrayList<Rune>()
}

func assembleCalls(acc: HashMap<Int32, SSECallAcc>): ArrayList<Call> {
    let idx = acc.keys().toArrayList()
    idx.sort()
    var out = ArrayList<Call>()
    for (i in idx) {
        let a = acc[i].getOrThrow()
        out.append(Call(a.id, a.name, String.fromRunes(a.args)))
    }
    out
}

func streamOpenAIChat(rd: InputStream, sink: FrameSink, tm: StreamTimer): ?(Reply, Bool, String, ?CodedError) {
    var r = Reply("", ArrayList<Call>())
    var acc = HashMap<Int32, SSECallAcc>()
    var done = false
    var fr = ""
    let sr = SSEReader(rd)
    while (true) {
        match (sr.next()) {
            case Some(payload) =>
                if (payload == "[DONE]") {
                    done = true
                    break
                }
                let json = match (JsonParser.parse(payload)) {
                    case Ok(j) => j
                    Err(e) => return (r, false, fr, CodedError(65, "SSE parse failed: ${e.message}"))
                }
                if (let obj: JsonObject <- json) {
                    if (let err <- obj.get("error")) {
                        if (let errObj: JsonObject <- err) {
                            if (let msg <- errObj.get("message")) {
                                if (let ms: JsonString <- msg) {
                                    if (ms.value != "") {
                                        return (r, false, fr, CodedError(65, "API error: ${ms.value}"))
                                    }
                                }
                            }
                        }
                    }
                    if (let choices <- obj.get("choices")) {
                        if (let arr: JsonArray <- choices) {
                            for (c in arr) {
                                if (let cObj: JsonObject <- c) {
                                    var finishReason = ""
                                    if (let fr <- cObj.get("finish_reason")) {
                                        if (let frs: JsonString <- fr) { finishReason = frs.value }
                                    }
                                    if (finishReason != "") { fr = finishReason }
                                    if (let delta <- cObj.get("delta")) {
                                        if (let dObj: JsonObject <- delta) {
                                            if (let rc <- dObj.get("reasoning_content")) {
                                                if (let rcs: JsonString <- rc) {
                                                    if (rcs.value != "") {
                                                        tm.mark()
                                                        sink(Frame(rcs.value, KIND_THINK, None, ""))
                                                    }
                                                }
                                            }
                                            if (let cv <- dObj.get("content")) {
                                                if (let cs: JsonString <- cv) {
                                                    if (cs.value != "") {
                                                        tm.mark()
                                                        sink(Frame(cs.value, KIND_ANSWER, None, ""))
                                                        r.text += cs.value
                                                    }
                                                }
                                            }
                                            if (let tc <- dObj.get("tool_calls")) {
                                                if (let tcArr: JsonArray <- tc) {
                                                    for (t in tcArr) {
                                                        if (let tObj: JsonObject <- t) {
                                                            var idx: Int32 = 0
                                                            if (let iv <- tObj.get("index")) {
                                                                if (let ii: JsonInt <- iv) { idx = Int32(ii.value) }
                                                            }
                                                            if (!acc.contains(idx)) {
                                                                acc.put(idx, SSECallAcc())
                                                            }
                                                            let a = acc[idx].getOrThrow()
                                                            if (let idv <- tObj.get("id")) {
                                                                if (let ids: JsonString <- idv) {
                                                                    if (ids.value != "") { a.id = ids.value }
                                                                }
                                                            }
                                                            if (let fv <- tObj.get("function")) {
                                                                if (let fObj: JsonObject <- fv) {
                                                                    if (let nv <- fObj.get("name")) {
                                                                        if (let ns: JsonString <- nv) {
                                                                            if (ns.value != "") { a.name = ns.value }
                                                                        }
                                                                    }
                                                                    if (let av <- fObj.get("arguments")) {
                                                                        if (let as_: JsonString <- av) {
                                                                            for (ch in as_.value.runes()) {
                                                                                a.args.append(ch)
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            None => break
        }
    }
    if (!done) {
        r.calls = assembleCalls(acc)
        if (!sr.clean()) {
            return (r, false, fr, CodedError(69, "stream error: ${sr.getErr().getOrThrow().message}"))
        }
        return (r, false, fr, CodedError(69, "stream ended early"))
    }
    r.calls = assembleCalls(acc)
    (r, true, fr, None)
}

func openAIToolSpecs(decls: ArrayList<ToolDecl>): ArrayList<ToolSpecWire> {
    var specs = ArrayList<ToolSpecWire>()
    for (d in decls) {
        specs.append(ToolSpecWire("function", FunctionSpec(d.name, d.description, d.parameters)))
    }
    specs
}

// ---------- Anthropic Messages ----------

class AnthroRequest {
    public var model: String
    public var maxTokens: Int32
    public var system: String
    public var messages: ArrayList<AnthroMsg>
    public var tools: ArrayList<AnthroTool>
    public var stream: Bool

    init(model: String, maxTokens: Int32, system: String, messages: ArrayList<AnthroMsg>,
        tools: ArrayList<AnthroTool>, stream: Bool) {
        this.model = model
        this.maxTokens = maxTokens
        this.system = system
        this.messages = messages
        this.tools = tools
        this.stream = stream
    }
}

class AnthroMsg {
    public var role: String
    public var content: ArrayList<AnthroBlock>

    init(role: String, content: ArrayList<AnthroBlock>) {
        this.role = role
        this.content = content
    }
}

class AnthroBlock {
    public var type_: String
    public var text: String
    public var id: String
    public var name: String
    public var input: String
    public var toolUseID: String
    public var result: String

    init(type_: String, text: String, id: String, name: String, input: String,
        toolUseID: String, result: String) {
        this.type_ = type_
        this.text = text
        this.id = id
        this.name = name
        this.input = input
        this.toolUseID = toolUseID
        this.result = result
    }
}

class AnthroTool {
    public var name: String
    public var description: String
    public var inputSchema: HashMap<String, Any>

    init(name: String, description: String, inputSchema: HashMap<String, Any>) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
    }
}

func buildAnthropic(messages: ArrayList<Msg>, st: Settings,
    decls: ArrayList<ToolDecl>): ?Array<UInt8> {
    var sys = ""
    var pendingResults = ArrayList<AnthroBlock>()
    var msgs = ArrayList<AnthroMsg>()

    for (m in messages) {
        switch (m.role) {
            case "system" =>
                if (sys != "") { sys += "\n\n" }
                sys += m.text
            case "assistant" =>
                if (pendingResults.size > 0) {
                    msgs.append(AnthroMsg("user", pendingResults))
                    pendingResults = ArrayList<AnthroBlock>()
                }
                var blocks = ArrayList<AnthroBlock>()
                if (m.text != "") {
                    blocks.append(AnthroBlock("text", m.text, "", "", "", "", ""))
                }
                for (c in m.calls) {
                    let input = argRaw(c.args)
                    blocks.append(AnthroBlock("tool_use", "", c.id, c.name, input, "", ""))
                }
                msgs.append(AnthroMsg("assistant", blocks))
            case "tool" =>
                pendingResults.append(AnthroBlock("tool_result", "", "", "", "", m.callID, m.text))
            case _ =>
                if (pendingResults.size > 0) {
                    msgs.append(AnthroMsg("user", pendingResults))
                    pendingResults = ArrayList<AnthroBlock>()
                }
                msgs.append(AnthroMsg("user", ArrayList<AnthroBlock>([AnthroBlock("text", m.text, "", "", "", "", "")])))
        }
    }
    if (pendingResults.size > 0) {
        msgs.append(AnthroMsg("user", pendingResults))
    }
    let tools = anthropicTools(decls)
    let req = AnthroRequest(st.model, st.maxTokens, sys, msgs, tools, st.stream)
    match (JsonParser.serialize(req)) {
        case Ok(s) => s.toUtf8()
        Err(e) => CodedError(65, "serialize request: ${e.message}")
    }
}

func argRaw(s: String): String {
    let t = s.trim()
    if (t == "") { "{}" } else { t }
}

func parseAnthropic(raw: Array<UInt8>, sink: FrameSink): ?CodedError {
    let str = String.fromUtf8(raw)
    let json = match (JsonParser.parse(str)) {
        case Ok(j) => j
        Err(e) => return CodedError(65, "parse response: ${e.message}")
    }
    if (let obj: JsonObject <- json) {
        if (let err <- obj.get("error")) {
            if (let errObj: JsonObject <- err) {
                if (let msg <- errObj.get("message")) {
                    if (let ms: JsonString <- msg) {
                        if (ms.value != "") {
                            return CodedError(65, "API error: ${ms.value}")
                        }
                    }
                }
            }
        }
        var stopReason = ""
        if (let sv <- obj.get("stop_reason")) {
            if (let ss: JsonString <- sv) { stopReason = ss.value }
        }
        var r = Reply("", ArrayList<Call>())
        if (let content <- obj.get("content")) {
            if (let arr: JsonArray <- content) {
                for (b in arr) {
                    if (let bObj: JsonObject <- b) {
                        var type_ = ""
                        if (let tv <- bObj.get("type")) {
                            if (let ts: JsonString <- tv) { type_ = ts.value }
                        }
                        switch (type_) {
                            case "text" =>
                                if (let tv <- bObj.get("text")) {
                                    if (let ts: JsonString <- tv) { r.text += ts.value }
                                }
                            case "tool_use" =>
                                var id = ""
                                var name = ""
                                var input = "{}"
                                if (let iv <- bObj.get("id")) {
                                    if (let is_: JsonString <- iv) { id = is_.value }
                                }
                                if (let nv <- bObj.get("name")) {
                                    if (let ns: JsonString <- nv) { name = ns.value }
                                }
                                if (let inp <- bObj.get("input")) {
                                    input = JsonParser.serialize(inp).getOrThrow()
                                }
                                r.calls.append(Call(id, name, input))
                            case _ => {}
                        }
                    }
                }
            }
        }
        sink(Frame("", "", r, stopReason))
    }
    None
}

class AnthroBlockAcc {
    var type_: String = ""
    var id: String = ""
    var name: String = ""
    var text: String = ""
    var input: ArrayList<Rune> = ArrayList<Rune>()
}

func collectBlocks(r: Reply, blocks: HashMap<Int32, AnthroBlockAcc]): Unit {
    let idx = blocks.keys().toArrayList()
    idx.sort()
    var text = ""
    for (i in idx) {
        let b = blocks[i].getOrThrow()
        switch (b.type_) {
            case "text" => text += b.text
            case "tool_use" =>
                var args = String.fromRunes(b.input)
                if (args.trim() == "") { args = "{}" }
                r.calls.append(Call(b.id, b.name, args))
            case _ => {}
        }
    }
    r.text = text
}

func streamAnthropic(rd: InputStream, sink: FrameSink, tm: StreamTimer): ?(Reply, Bool, String, ?CodedError) {
    var r = Reply("", ArrayList<Call>())
    var blocks = HashMap<Int32, AnthroBlockAcc>()
    var done = false
    var fr = ""
    let sr = SSEReader(rd)
    while (true) {
        match (sr.next()) {
            Some(payload) =>
                let json = match (JsonParser.parse(payload)) {
                    case Ok(j) => j
                    Err(e) => return (r, false, fr, CodedError(65, "SSE parse failed: ${e.message}"))
                }
                if (let obj: JsonObject <- json) {
                    var type_ = ""
                    if (let tv <- obj.get("type")) {
                        if (let ts: JsonString <- tv) { type_ = ts.value }
                    }
                    switch (type_) {
                        case "error" =>
                            var msg = ""
                            if (let ev <- obj.get("error")) {
                                if (let eObj: JsonObject <- ev) {
                                    if (let mv <- eObj.get("message")) {
                                        if (let ms: JsonString <- mv) { msg = ms.value }
                                    }
                                }
                            }
                            return (r, false, fr, CodedError(65, "API error: ${msg}"))
                        case "message_stop" =>
                            done = true
                        case "content_block_start" =>
                            var idx: Int32 = 0
                            if (let iv <- obj.get("index")) {
                                if (let ii: JsonInt <- iv) { idx = Int32(ii.value) }
                            }
                            if (let cb <- obj.get("content_block")) {
                                if (let cbObj: JsonObject <- cb) {
                                    var bt = ""
                                    var id = ""
                                    var name = ""
                                    if (let tv <- cbObj.get("type")) {
                                        if (let ts: JsonString <- tv) { bt = ts.value }
                                    }
                                    if (let idv <- cbObj.get("id")) {
                                        if (let ids: JsonString <- idv) { id = ids.value }
                                    }
                                    if (let nv <- cbObj.get("name")) {
                                        if (let ns: JsonString <- nv) { name = ns.value }
                                    }
                                    blocks.put(idx, AnthroBlockAcc())
                                    let acc = blocks[idx].getOrThrow()
                                    acc.type_ = bt
                                    acc.id = id
                                    acc.name = name
                                }
                            }
                        case "content_block_delta" =>
                            var idx: Int32 = 0
                            if (let iv <- obj.get("index")) {
                                if (let ii: JsonInt <- iv) { idx = Int32(ii.value) }
                            }
                            if (let delta <- obj.get("delta")) {
                                if (let dObj: JsonObject <- delta) {
                                    if (!blocks.contains(idx)) {
                                        continue
                                    }
                                    let b = blocks[idx].getOrThrow()
                                    var stopReason = ""
                                    if (let sv <- dObj.get("stop_reason")) {
                                        if (let ss: JsonString <- sv) { stopReason = ss.value }
                                    }
                                    if (stopReason != "") { fr = stopReason }
                                    var deltaType = ""
                                    if (let tv <- dObj.get("type")) {
                                        if (let ts: JsonString <- tv) { deltaType = ts.value }
                                    }
                                    switch (deltaType) {
                                        case "text_delta" =>
                                            if (let tv <- dObj.get("text")) {
                                                if (let ts: JsonString <- tv) {
                                                    tm.mark()
                                                    sink(Frame(ts.value, KIND_ANSWER, None, ""))
                                                    b.text += ts.value
                                                }
                                            }
                                        case "thinking_delta" =>
                                            if (let tv <- dObj.get("thinking")) {
                                                if (let ts: JsonString <- tv) {
                                                    tm.mark()
                                                    sink(Frame(ts.value, KIND_THINK, None, ""))
                                                }
                                            }
                                        case "input_json_delta" =>
                                            if (let pv <- dObj.get("partial_json")) {
                                                if (let ps: JsonString <- pv) {
                                                    for (ch in ps.value.runes()) {
                                                        b.input.append(ch)
                                                    }
                                                }
                                            }
                                        case _ => {}
                                    }
                                }
                            }
                        case _ => {}
                    }
                    if (done) { break }
                }
            None => break
        }
    }
    if (!done) {
        collectBlocks(r, blocks)
        if (!sr.clean()) {
            return (r, false, fr, CodedError(69, "stream error: ${sr.getErr().getOrThrow().message}"))
        }
        return (r, false, fr, CodedError(69, "stream ended early"))
    }
    collectBlocks(r, blocks)
    (r, true, fr, None)
}

func anthropicTools(decls: ArrayList<ToolDecl>): ArrayList<AnthroTool> {
    var ts = ArrayList<AnthroTool>()
    for (d in decls) {
        ts.append(AnthroTool(d.name, d.description, d.parameters))
    }
    ts
}

// ---------- OpenAI Responses ----------

class ResponsesRequest {
    public var model: String
    public var instructions: String
    public var input: ArrayList<RespItem>
    public var maxOutputTokens: Int32
    public var tools: ArrayList<ResponsesTool>
    public var stream: Bool

    init(model: String, instructions: String, input: ArrayList<RespItem>,
        maxOutputTokens: Int32, tools: ArrayList<ResponsesTool>, stream: Bool) {
        this.model = model
        this.instructions = instructions
        this.input = input
        this.maxOutputTokens = maxOutputTokens
        this.tools = tools
        this.stream = stream
    }
}

class RespItem {
    public var type_: String
    public var role: String
    public var content: String
    public var callID: String
    public var name: String
    public var arguments: String
    public var output: String

    init(type_: String, role: String, content: String, callID: String, name: String,
        arguments: String, output: String) {
        this.type_ = type_
        this.role = role
        this.content = content
        this.callID = callID
        this.name = name
        this.arguments = arguments
        this.output = output
    }
}

class ResponsesTool {
    public var type_: String
    public var name: String
    public var description: String
    public var parameters: HashMap<String, Any>

    init(type_: String, name: String, description: String, parameters: HashMap<String, Any>) {
        this.type_ = type_
        this.name = name
        this.description = description
        this.parameters = parameters
    }
}

func buildResponses(messages: ArrayList<Msg>, st: Settings,
    decls: ArrayList<ToolDecl>): ?Array<UInt8> {
    var sys = ""
    var input = ArrayList<RespItem>()
    for (m in messages) {
        switch (m.role) {
            case "system" =>
                if (sys != "") { sys += "\n\n" }
                sys += m.text
            case "assistant" =>
                if (m.text != "") {
                    input.append(RespItem("message", "assistant", m.text, "", "", "", ""))
                }
                for (c in m.calls) {
                    input.append(RespItem("function_call", "", "", c.id, c.name, c.args, ""))
                }
            case "tool" =>
                input.append(RespItem("function_call_output", "", "", m.callID, "", "", m.text))
            case _ =>
                input.append(RespItem("message", "user", m.text, "", "", "", ""))
        }
    }
    let tools = responsesTools(decls)
    let req = ResponsesRequest(st.model, sys, input, st.maxTokens, tools, st.stream)
    match (JsonParser.serialize(req)) {
        case Ok(s) => s.toUtf8()
        Err(e) => CodedError(65, "serialize request: ${e.message}")
    }
}

class RespOutputItem {
    public var type_: String
    public var role: String
    public var content: ArrayList<RespContent>
    public var callID: String
    public var name: String
    public var arguments: String

    init(type_: String, role: String, content: ArrayList<RespContent>, callID: String,
        name: String, arguments: String) {
        this.type_ = type_
        this.role = role
        this.content = content
        this.callID = callID
        this.name = name
        this.arguments = arguments
    }
}

class RespContent {
    public var type_: String
    public var text: String

    init(type_: String, text: String) {
        this.type_ = type_
        this.text = text
    }
}

func replyFromRespItems(items: ArrayList<RespOutputItem>): Reply {
    var r = Reply("", ArrayList<Call>())
    for (item in items) {
        switch (item.type_) {
            case "message" =>
                for (c in item.content) {
                    r.text += c.text
                }
            case "function_call" =>
                r.calls.append(Call(item.callID, item.name, item.arguments))
            case _ => {}
        }
    }
    r
}

func parseResponses(raw: Array<UInt8>, sink: FrameSink): ?CodedError {
    let str = String.fromUtf8(raw)
    let json = match (JsonParser.parse(str)) {
        case Ok(j) => j
        Err(e) => return CodedError(65, "parse response: ${e.message}")
    }
    if (let obj: JsonObject <- json) {
        if (let err <- obj.get("error")) {
            if (let errObj: JsonObject <- err) {
                if (let msg <- errObj.get("message")) {
                    if (let ms: JsonString <- msg) {
                        if (ms.value != "") {
                            return CodedError(65, "API error: ${ms.value}")
                        }
                    }
                }
            }
        }
        var status = ""
        if (let sv <- obj.get("status")) {
            if (let ss: JsonString <- sv) { status = ss.value }
        }
        var fr = ""
        if (status == "incomplete") { fr = "incomplete" }
        var items = ArrayList<RespOutputItem>()
        if (let output <- obj.get("output")) {
            if (let arr: JsonArray <- output) {
                for (item in arr) {
                    if (let iObj: JsonObject <- item) {
                        var type_ = ""
                        var role = ""
                        var callID = ""
                        var name = ""
                        var arguments = ""
                        var content = ArrayList<RespContent>()
                        if (let tv <- iObj.get("type")) {
                            if (let ts: JsonString <- tv) { type_ = ts.value }
                        }
                        if (let rv <- iObj.get("role")) {
                            if (let rs: JsonString <- rv) { role = rs.value }
                        }
                        if (let cv <- iObj.get("call_id")) {
                            if (let cs: JsonString <- cv) { callID = cs.value }
                        }
                        if (let nv <- iObj.get("name")) {
                            if (let ns: JsonString <- nv) { name = ns.value }
                        }
                        if (let av <- iObj.get("arguments")) {
                            if (let as_: JsonString <- av) { arguments = as_.value }
                        }
                        if (let ct <- iObj.get("content")) {
                            if (let ctArr: JsonArray <- ct) {
                                for (c in ctArr) {
                                    if (let cObj: JsonObject <- c) {
                                        var ctType = ""
                                        var ctText = ""
                                        if (let tv <- cObj.get("type")) {
                                            if (let ts: JsonString <- tv) { ctType = ts.value }
                                        }
                                        if (let tv <- cObj.get("text")) {
                                            if (let ts: JsonString <- tv) { ctText = ts.value }
                                        }
                                        content.append(RespContent(ctType, ctText))
                                    }
                                }
                            }
                        }
                        items.append(RespOutputItem(type_, role, content, callID, name, arguments))
                    }
                }
            }
        }
        sink(Frame("", "", replyFromRespItems(items), fr))
    }
    None
}

func streamResponses(rd: InputStream, sink: FrameSink, tm: StreamTimer): ?(Reply, Bool, String, ?CodedError) {
    var r = Reply("", ArrayList<Call>())
    var done = false
    var fr = ""
    let sr = SSEReader(rd)
    while (true) {
        match (sr.next()) {
            Some(payload) =>
                let json = match (JsonParser.parse(payload)) {
                    case Ok(j) => j
                    Err(e) => return (r, false, fr, CodedError(65, "SSE parse failed: ${e.message}"))
                }
                if (let obj: JsonObject <- json) {
                    var type_ = ""
                    if (let tv <- obj.get("type")) {
                        if (let ts: JsonString <- tv) { type_ = ts.value }
                    }
                    switch (type_) {
                        case "response.output_text.delta" =>
                            if (let dv <- obj.get("delta")) {
                                if (let ds: JsonString <- dv) {
                                    tm.mark()
                                    sink(Frame(ds.value, KIND_ANSWER, None, ""))
                                    r.text += ds.value
                                }
                            }
                        case "response.completed" | "response.done" =>
                            if (let resp <- obj.get("response")) {
                                if (let rObj: JsonObject <- resp) {
                                    if (let err <- rObj.get("error")) {
                                        if (let eObj: JsonObject <- err) {
                                            if (let mv <- eObj.get("message")) {
                                                if (let ms: JsonString <- mv) {
                                                    if (ms.value != "") {
                                                        return (r, false, fr, CodedError(65, "API error: ${ms.value}"))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    var status = ""
                                    if (let sv <- rObj.get("status")) {
                                        if (let ss: JsonString <- sv) { status = ss.value }
                                    }
                                    if (status == "incomplete") { fr = "incomplete" }
                                    var items = ArrayList<RespOutputItem>()
                                    if (let output <- rObj.get("output")) {
                                        if (let arr: JsonArray <- output) {
                                            for (item in arr) {
                                                if (let iObj: JsonObject <- item) {
                                                    var itType = ""
                                                    var itRole = ""
                                                    var itCallID = ""
                                                    var itName = ""
                                                    var itArgs = ""
                                                    var itContent = ArrayList<RespContent>()
                                                    if (let tv <- iObj.get("type")) {
                                                        if (let ts: JsonString <- tv) { itType = ts.value }
                                                    }
                                                    if (let rv <- iObj.get("role")) {
                                                        if (let rs: JsonString <- rv) { itRole = rs.value }
                                                    }
                                                    if (let cv <- iObj.get("call_id")) {
                                                        if (let cs: JsonString <- cv) { itCallID = cs.value }
                                                    }
                                                    if (let nv <- iObj.get("name")) {
                                                        if (let ns: JsonString <- nv) { itName = ns.value }
                                                    }
                                                    if (let av <- iObj.get("arguments")) {
                                                        if (let as_: JsonString <- av) { itArgs = as_.value }
                                                    }
                                                    if (let ct <- iObj.get("content")) {
                                                        if (let ctArr: JsonArray <- ct) {
                                                            for (c in ctArr) {
                                                                if (let cObj: JsonObject <- c) {
                                                                    var ctType = ""
                                                                    var ctText = ""
                                                                    if (let tv <- cObj.get("type")) {
                                                                        if (let ts: JsonString <- tv) { ctType = ts.value }
                                                                    }
                                                                    if (let tv <- cObj.get("text")) {
                                                                        if (let ts: JsonString <- tv) { ctText = ts.value }
                                                                    }
                                                                    itContent.append(RespContent(ctType, ctText))
                                                                }
                                                            }
                                                        }
                                                    }
                                                    items.append(RespOutputItem(itType, itRole, itContent, itCallID, itName, itArgs))
                                                }
                                            }
                                        }
                                    }
                                    r = replyFromRespItems(items)
                                    done = true
                                }
                            }
                        case "response.failed" | "error" =>
                            var msg = ""
                            if (let resp <- obj.get("response")) {
                                if (let rObj: JsonObject <- resp) {
                                    if (let err <- rObj.get("error")) {
                                        if (let eObj: JsonObject <- err) {
                                            if (let mv <- eObj.get("message")) {
                                                if (let ms: JsonString <- mv) { msg = ms.value }
                                            }
                                        }
                                    }
                                }
                            }
                            return (r, false, fr, CodedError(65, "API error: ${msg}"))
                        case _ => {}
                    }
                    if (done) { break }
                }
            None => break
        }
    }
    if (!done) {
        if (!sr.clean()) {
            return (r, false, fr, CodedError(69, "stream error: ${sr.getErr().getOrThrow().message}"))
        }
        return (r, false, fr, CodedError(69, "stream ended early"))
    }
    (r, true, fr, None)
}

func responsesTools(decls: ArrayList<ToolDecl>): ArrayList<ResponsesTool> {
    var ts = ArrayList<ResponsesTool>()
    for (d in decls) {
        ts.append(ResponsesTool("function", d.name, d.description, d.parameters))
    }
    ts
}
