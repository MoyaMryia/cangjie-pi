// Wire: shared plumbing for protocol adapters (JSON helpers, SSE reading, stream timing).
package cpi.internal.wire

import std.io.*
import std.json.*
import std.time.*

import cpi.internal.apperr.*

public func readAll(r: InputStream): ?Array<UInt8> {
    let buf = ArrayList<UInt8>()
    let chunk = Array<UInt8>(4096, item: 0)
    while (true) {
        let n = match (r.read(chunk)) {
            case Ok(n) => n
            Err(e) => return None
        }
        if (n == 0) {
            break
        }
        for (i in 0..n) {
            buf.append(chunk[i])
        }
    }
    buf.toArray()
}

public func parseBody(raw: Array<UInt8>, typeName: String): ?Any {
    let str = String.fromUtf8(raw)
    match (JsonParser.parse(str)) {
        case Ok(j) => j
        Err(e) => CodedError(65, "parse response: ${e.message}")
    }
}

public class StreamTimer {
    public let t0: DateTime
    public var first: ?DateTime = None

    public init() {
        t0 = DateTime.now()
    }

    public func mark() {
        if (first.isNone()) {
            first = DateTime.now()
        }
    }
}

public class SSEReader {
    let brd: BufferedInputStream
    var err: ?Exception = None

    public init(rd: InputStream) {
        brd = BufferedInputStream(rd, 65536)
    }

    public func next(): ?(String) {
        while (true) {
            let line = match (brd.readLine()) {
                case Ok(l) => l
                Err(e) =>
                    err = e
                    if (e.message.contains("EOF")) {
                        err = Exception("unexpected EOF")
                    }
                    return None
            }
            let trimmed = line.trim()
            if (trimmed == "" || trimmed.startsWith(":") || trimmed.startsWith("event:") ||
                trimmed.startsWith("id:") || trimmed.startsWith("retry:") ||
                !trimmed.startsWith("data:")) {
                continue
            }
            return trimmed.substring(5).trim()
        }
    }

    public func getErr(): ?Exception { err }

    public func clean(): Bool {
        match (err) {
            case Some(e) => e.message == "unexpected EOF"
            case None => true
        }
    }
}
