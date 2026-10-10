// CTL: inherited control channel between TUI and agent.
package cpi.internal.ctl

import std.io.*
import std.json.*
import std.os.*
import std.sync.*

public class Phase <: Comparable<Phase> {
    public let name: String

    public init(name: String) { this.name = name }

    public func compareTo(other: Phase): Int32 {
        name.compare(other.name)
    }

    public func toString(): String { name }
}

public let PHASE_MODEL = Phase("model")
public let PHASE_TOOL = Phase("tool")
public let PHASE_DONE = Phase("done")
public let PHASE_WAIT = Phase("wait_eof")
public let PHASE_END = Phase("end")

class Message {
    public var e: String
    public var phase: String

    init(e: String, phase: String) {
        this.e = e
        this.phase = phase
    }
}

public class Control {
    var rd: BufferedInputStream
    var w: OutputStream
    var onInterrupt: ?(() -> Unit)
    var gone: Bool = false
    var mu = Mutex()
    var stopFlag: Bool = false

    init(rd: BufferedInputStream, w: OutputStream, onInterrupt: ?(() -> Unit)) {
        this.rd = rd
        this.w = w
        this.onInterrupt = onInterrupt
        spawn readLoop()
    }

    func readLoop() {
        while (true) {
            let line = match (rd.readLine()) {
                case Ok(l) => l
                Err(e) =>
                    markGone()
                    return
            }
            if (line != "") {
                handle(line)
            }
        }
    }

    func handle(line: String) {
        let json = match (JsonParser.parse(line)) {
            case Ok(j) => j
            Err(e) => return
        }
        if (let obj: JsonObject <- json) {
            if (let ev <- obj.get("e")) {
                if (let es: JsonString <- ev) {
                    if (es.value == "interrupt") {
                        match (onInterrupt) {
                            case Some(f) => f()
                            case None => {}
                        }
                    }
                }
            }
        }
    }

    func markGone() {
        mu.lock()
        if (!gone) {
            gone = true
        }
        mu.unlock()
    }

    public func isGone(): Bool {
        mu.lock()
        let g = gone
        mu.unlock()
        g
    }

    public func waitGone() {
        while (!isGone()) {
            sleep(Duration.millisecond(10))
        }
    }

    public func phase(p: Phase) {
        let msg = Message("phase", p.name)
        let json = match (JsonParser.serialize(msg)) {
            case Ok(s) => s
            Err(e) => return
        }
        let bytes = (json + "\n").toUtf8()
        match (w.write(bytes)) {
            case Ok(n) => {}
            Err(e) => {}
        }
    }

    public func close() {
        mu.lock()
        stopFlag = true
        mu.unlock()
        markGone()
        w.close()
    }
}

public func open(fd: Int32, onInterrupt: ?(() -> Unit)): ?Control {
    let file = os.newFile(fd)
    if (file.isNone()) {
        return None
    }
    let f = file.getOrThrow()
    let rd = BufferedInputStream(f)
    Control(rd, f, onInterrupt)
}
