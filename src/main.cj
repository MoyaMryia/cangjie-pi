// Entry point for cpi agent.
package main

import std.io.*
import std.os.*
import std.time.*
import std.collection.*

import cpi.internal.apperr.*
import cpi.internal.config.*
import cpi.internal.ctl.*
import cpi.internal.cycle.*
import cpi.internal.session.*

let VERSION = "0.0.10"

class InterruptCtx {
    var cancelled = false
    let mu = Mutex()

    init() {}

    func cancel() {
        mu.lock()
        cancelled = true
        mu.unlock()
    }

    func isCancelled(): Bool {
        mu.lock()
        let c = cancelled
        mu.unlock()
        c
    }

    func reset() {
        mu.lock()
        cancelled = false
        mu.unlock()
    }
}

func main(args: ArrayList<String>): Int32 {
    if (args.size < 1) {
        stderr.write("Usage: cpi \"your task\"\n".toUtf8())
        return 2
    }

    let fdRaw = match (os.getenv("CPI_CONTROL_FD")) {
        case Some(v) => v
        case None =>
            stderr.write("Error: no control FD (CPI_CONTROL_FD not set), refusing to execute\n".toUtf8())
            return 2
    }
    let fd = match (fdRaw.toInt32()) {
        case Some(n) => n
        case None =>
            stderr.write("Error: CPI_CONTROL_FD not integer: ${fdRaw}\n".toUtf8())
            return 2
    }

    let st = match (config.loadSettings()) {
        case Some(s) => s
        case None =>
            stderr.write("Error: failed to load settings\n".toUtf8())
            return 78
    }

    let cwd = match (os.cwd()) {
        case Some(c) => c
        case None =>
            stderr.write("Error: cannot get cwd\n".toUtf8())
            return 78
    }

    let sess = match (session.openOrCreate(cwd, st.model, st.protocol, st.apiBase, st.maxTokens)) {
        case Some(s) => s
        case None =>
            stderr.write("Error: failed to open/create session\n".toUtf8())
            return 78
    }

    let ctx = InterruptCtx()
    let ctrl = match (ctl.open(fd, { _: Unit => ctx.cancel() })) {
        case Some(c) => c
        case None =>
            stderr.write("Error: failed to open control channel\n".toUtf8())
            return 78
    }

    let (answer, err) = match (cycle.runMain(ctx, sess, args[0], st, ctrl)) {
        case Some((ans, e)) => (ans, e)
        case None => ("", Exception("cycle failed"))
    }

    sess.close()
    ctrl.close()

    if (err.message != "") {
        stderr.write("Error: ${err.message}\n".toUtf8())
        return match (apperr.exitCodeOf(err)) {
            case Some(code) => code
            case None => 1
        }
    }

    stdout.write(answer.toUtf8())
    stdout.write("\n".toUtf8())
    0
}
