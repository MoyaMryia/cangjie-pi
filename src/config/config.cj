// Config: external input loading, system prompt assembly, protocol registry.
package cpi.internal.config

import std.io.*
import std.os.*
import std.json.*
import std.collection.*
import std.fs.*

import cpi.internal.apperr.*

public let DEFAULT_API_BASE = "https://opencode.ai/zen/v1"
public let DEFAULT_MODEL = "hy3-free"
public let DEFAULT_MAX_TOKENS = 32000
public let DEFAULT_TIMEOUT_SEC = 30
public let PROTO_OPENAI_CHAT = "openai-chat"
public let PROTO_ANTHROPIC_MSGS = "anthropic-messages"
public let PROTO_OPENAI_RESPONSES = "openai-responses"
public let PROTO_DEFAULT = PROTO_OPENAI_CHAT

public class Settings {
    public var apiBase: String
    public var model: String
    public var protocol: String
    public var maxTokens: Int32
    public var timeoutSec: Int32
    public var stream: Bool

    public init(apiBase: String, model: String, protocol: String, maxTokens: Int32,
        timeoutSec: Int32, stream: Bool) {
        this.apiBase = apiBase
        this.model = model
        this.protocol = protocol
        this.maxTokens = maxTokens
        this.timeoutSec = timeoutSec
        this.stream = stream
    }
}

public func validProtocol(p: String): Bool {
    p == PROTO_OPENAI_CHAT || p == PROTO_ANTHROPIC_MSGS || p == PROTO_OPENAI_RESPONSES
}

public func loadSettings(): ?Settings {
    let st = Settings(DEFAULT_API_BASE, DEFAULT_MODEL, PROTO_DEFAULT, DEFAULT_MAX_TOKENS,
        DEFAULT_TIMEOUT_SEC, true)

    let home = match (os.homeDir()) {
        case Some(h) => h
        case None => return st
    }
    let dir = Path(home).join(".config").join("cpi")

    match (loadProvider(dir.join("provider.json").toString(), st)) {
        case Some(e) => return None
        case None => {}
    }
    match (loadConfig(dir.join("config.json").toString(), st)) {
        case Some(e) => return None
        case None => {}
    }
    st
}

class ProviderModel {
    public var protocol: String
    public var maxOutputTokens: ?Int32

    init(protocol: String, maxOutputTokens: ?Int32) {
        this.protocol = protocol
        this.maxOutputTokens = maxOutputTokens
    }
}

class ProviderEntry {
    public var name: String
    public var baseURL: String
    public var models: HashMap<String, ProviderModel>

    init(name: String, baseURL: String, models: HashMap<String, ProviderModel>) {
        this.name = name
        this.baseURL = baseURL
        this.models = models
    }
}

func loadProvider(path: String, st: Settings): ?CodedError {
    let content = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }

    let json = match (JsonParser.parse(content)) {
        case Ok(j) => j
        Err(e) => return CodedError(78, "provider.json parse failed: ${e.message}")
    }

    if (let obj: JsonObject <- json) {
        if (let providerVal <- obj.get("provider")) {
            if (let providerObj: JsonObject <- providerVal) {
                for ((pname, pval) in providerObj) {
                    if (let p: JsonObject <- pval) {
                        var baseURL = ""
                        if (let opts <- p.get("options")) {
                            if (let optsObj: JsonObject <- opts) {
                                if (let b <- optsObj.get("baseURL")) {
                                    if (let bs: JsonString <- b) {
                                        baseURL = bs.value
                                    }
                                }
                            }
                        }
                        var models = HashMap<String, ProviderModel>()
                        if (let m <- p.get("models")) {
                            if (let mObj: JsonObject <- m) {
                                for ((mname, mval) in mObj) {
                                    if (let mm: JsonObject <- mval) {
                                        var proto = ""
                                        if (let pv <- mm.get("protocol")) {
                                            if (let ps: JsonString <- pv) {
                                                proto = ps.value
                                            }
                                        }
                                        var maxOut: ?Int32 = None
                                        if (let mv <- mm.get("maxOutputTokens")) {
                                            if (let mi: JsonInt <- mv) {
                                                maxOut = Int32(mi.value)
                                            }
                                        }
                                        models.put(mname, ProviderModel(proto, maxOut))
                                    }
                                }
                            }
                        }
                        if (models.size == 1) {
                            let entry = models.values().next().getOrThrow()
                            if (baseURL != "") {
                                st.apiBase = baseURL
                            }
                            st.model = models.keys().next().getOrThrow()
                            match (entry.maxOutputTokens) {
                                case Some(mo) => if (mo > 0) { st.maxTokens = mo }
                                case None => {}
                            }
                            if (entry.protocol != "") {
                                if (!validProtocol(entry.protocol)) {
                                    return CodedError(78, "unknown protocol: ${entry.protocol}")
                                }
                                st.protocol = entry.protocol
                            }
                        } else if (models.size == 0) {
                            return CodedError(78, "no usable model in provider.json")
                        } else {
                            return CodedError(78, "multiple models, cannot auto-select")
                        }
                    }
                }
            }
        }
    }
    None
}

func loadConfig(path: String, st: Settings): ?CodedError {
    let content = match (fs.readToString(path)) {
        case Ok(c) => c
        Err(e) => return None
    }

    let json = match (JsonParser.parse(content)) {
        case Ok(j) => j
        Err(e) => return CodedError(78, "config.json parse failed: ${e.message}")
    }

    if (let obj: JsonObject <- json) {
        if (let mt <- obj.get("max_tokens")) {
            if (let mi: JsonInt <- mt) {
                if (mi.value > 0) {
                    st.maxTokens = Int32(mi.value)
                }
            }
        }
        if (let bs <- obj.get("bash_timeout_seconds")) {
            if (let bi: JsonInt <- bs) {
                if (bi.value > 0) {
                    st.timeoutSec = Int32(bi.value)
                }
            }
        }
        if (let sv <- obj.get("stream")) {
            if (let sb: JsonBool <- sv) {
                st.stream = sb.value
            }
        }
    }
    None
}

func extractSystem(md: String): String {
    let lines = ArrayList<String>()
    for (line in md.split("\n")) {
        let trimmed = line.trim()
        if (trimmed.startsWith("#") || trimmed.startsWith(">")) {
            continue
        }
        lines.append(trimmed)
    }
    lines.join("\n")
}

public func loadSystemPrompt(): String {
    let home = match (os.homeDir()) {
        case Some(h) => h
        case None => return ""
    }
    let base = Path(home).join(".config").join("cpi")
    let parts = ArrayList<String>()
    for (name in ["system.md", "AGENTS.md", "SELF.md"]) {
        let content = match (fs.readToString(base.join(name).toString())) {
            case Ok(c) => c
            Err(e) => continue
        }
        let extracted = extractSystem(content)
        if (extracted != "") {
            parts.append(extracted)
        }
    }
    parts.join("\n\n")
}
