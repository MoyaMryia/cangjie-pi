// IR: neutral intermediate representation for agent loop layers.
package cpi.internal.ir

public class ToolDecl {
    public let name: String
    public let description: String
    public let parameters: HashMap<String, Any>

    public init(name: String, description: String, parameters: HashMap<String, Any>) {
        this.name = name
        this.description = description
        this.parameters = parameters
    }
}

public class Msg {
    public var role: String
    public var text: String
    public var calls: ArrayList<Call>
    public var callID: String

    public init(role: String, text: String, calls: ArrayList<Call>, callID: String) {
        this.role = role
        this.text = text
        this.calls = calls
        this.callID = callID
    }
}

public class Call {
    public let id: String
    public let name: String
    public let args: String

    public init(id: String, name: String, args: String) {
        this.id = id
        this.name = name
        this.args = args
    }
}

public class Reply {
    public var text: String
    public var calls: ArrayList<Call>

    public init(text: String, calls: ArrayList<Call>) {
        this.text = text
        this.calls = calls
    }
}

public class Frame {
    public var deltaText: String
    public var deltaKind: String
    public var final_: ?Reply
    public var finishReason: String

    public init(deltaText: String, deltaKind: String, final_: ?Reply, finishReason: String) {
        this.deltaText = deltaText
        this.deltaKind = deltaKind
        this.final_ = final_
        this.finishReason = finishReason
    }
}

public type FrameSink = (Frame) -> Unit

public class ChatOutcome {
    public var reply: ?Reply
    public var partial: Bool
    public var cause: String
    public var raw: Array<UInt8>
    public var rawCut: Bool
    public var finishReason: String

    public init(reply: ?Reply, partial: Bool, cause: String, raw: Array<UInt8>, rawCut: Bool,
        finishReason: String) {
        this.reply = reply
        this.partial = partial
        this.cause = cause
        this.raw = raw
        this.rawCut = rawCut
        this.finishReason = finishReason
    }
}

public const KIND_THINK = "think"
public const KIND_ANSWER = "answer"
public const CAUSE_BROKEN = "broken"
public const CAUSE_INTERRUPTED = "interrupted"
