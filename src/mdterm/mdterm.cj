// Mdterm: Markdown to ANSI terminal renderer.
package cpi.internal.mdterm

import std.io.*
import std.collection.*

let reset = "\u001b[0m"
let italic = "\u001b[3m"
let underline = "\u001b[4m"
let dim = "\u001b[2m"
let cyan = "\u001b[36m"
let boldStyle = "\u001b[1;38;2;80;200;120m"

public class Renderer {
    let out: OutputStream
    var inFence: Bool = false
    var fenceChar: Rune = " "
    var fenceLen: Int32 = 0
    var maxCols: Int32 = 0
    var cols: Int32 = 0

    init(out: OutputStream) {
        this.out = out
    }

    public func setMaxCols(n: Int32) { maxCols = n }

    public func renderLine(line: String): Unit {
        cols = 0
        if (line.trim() == "") {
            out.write("\n".toUtf8())
            return
        }
        let pos = leadingSpaces(line)
        if (inFence) {
            let n = countRun(line, pos, fenceChar)
            if (n >= fenceLen && restSpaces(line, pos + n)) {
                inFence = false
                out.write(dim.toUtf8())
                emitText(line.substring(pos))
                out.write(reset.toUtf8())
            } else {
                out.write(dim.toUtf8())
                emitText(line)
                out.write(reset.toUtf8())
            }
            return
        }
        if (pos < line.byteLength() && (line[pos] == "`" || line[pos] == "~")) {
            let fc = line[pos]
            let n = countRun(line, pos, fc)
            var hasFence = false
            for (j in pos + n..line.byteLength()) {
                if (line[j] == fc) {
                    hasFence = true
                    break
                }
            }
            if (n >= 3 && !hasFence) {
                inFence = true
                fenceChar = fc
                fenceLen = n
                out.write(dim.toUtf8())
                emitText(line.substring(pos))
                out.write(reset.toUtf8())
                return
            }
        }
        if (pos < line.byteLength() && line[pos] == "#") {
            let level = countRun(line, pos, "#")
            if (level >= 1 && level <= 6 && pos + level < line.byteLength() && line[pos + level] == " ") {
                emitInline(line.substring(pos + level + 1), true, false, level == 1)
                out.write(reset.toUtf8())
                return
            }
        }
        if (isHR(line)) {
            out.write(dim.toUtf8())
            emitText("---")
            out.write(reset.toUtf8())
            return
        }
        if (pos < line.byteLength() && line[pos] == ">") {
            var after = pos + 1
            if (after < line.byteLength() && line[after] == " ") {
                after++
            }
            out.write(dim.toUtf8())
            out.write("│ ".toUtf8())
            out.write(reset.toUtf8())
            emitInline(line.substring(after), false, true, false)
            out.write(reset.toUtf8())
            return
        }
        if (pos < line.byteLength() && (line[pos] == "-" || line[pos] == "*" || line[pos] == "+") &&
            pos + 1 < line.byteLength() && line[pos + 1] == " ") {
            for (i in 0..pos) {
                emitText(" ")
            }
            out.write("• ".toUtf8())
            emitInline(line.substring(pos + 2), false, false, false)
            return
        }
        if (pos < line.byteLength() && line[pos] >= "0" && line[pos] <= "9") {
            var d = pos
            while (d < line.byteLength() && line[d] >= "0" && line[d] <= "9") {
                d++
            }
            if (d < line.byteLength() && line[d] == "." && d + 1 < line.byteLength() && line[d + 1] == " ") {
                for (i in 0..pos) {
                    emitText(" ")
                }
                emitText(line.substring(pos, d + 1))
                emitText(" ")
                emitInline(line.substring(d + 2), false, false, false)
                return
            }
        }
        emitInline(line, false, false, false)
    }

    public func reset(): Unit {
        inFence = false
        fenceChar = " "
        fenceLen = 0
    }

    func leadingSpaces(s: String): Int32 {
        var n: Int32 = 0
        while (n < s.byteLength() && s[n] == " ") {
            n++
        }
        n
    }

    func countRun(s: String, pos: Int32, c: Rune): Int32 {
        var n: Int32 = 0
        while (pos + n < s.byteLength() && s[pos + n] == c) {
            n++
        }
        n
    }

    func restSpaces(s: String, pos: Int32): Bool {
        var p = pos
        while (p < s.byteLength()) {
            if (s[p] != " " && s[p] != "\t") {
                return false
            }
            p++
        }
        true
    }

    func isHR(s: String): Bool {
        var c: Rune = " "
        var n: Int32 = 0
        for (i in 0..s.byteLength()) {
            if (s[i] == " " || s[i] == "\t") { continue }
            if (c == " ") {
                if (s[i] != "-" && s[i] != "*" && s[i] != "_") {
                    return false
                }
                c = s[i]
                n = 1
            } else if (s[i] == c) {
                n++
            } else {
                return false
            }
        }
        n >= 3
    }

    func emitText(s: String): Unit {
        for (ch in s.runes()) {
            let c = Int32(ch.value)
            if (c == 9) {
                out.write("\t".toUtf8())
                cols++
            } else if (c < 32 || c == 127) {
                out.write("\\x${c.toHex(2)}".toUtf8())
                cols += 4
            } else {
                out.write(String.fromRune(ch).toUtf8())
                cols++
            }
            if (maxCols > 0 && cols >= maxCols) {
                out.write("\n".toUtf8())
                cols = 0
            }
        }
    }

    func sgr(b: Bool, i: Bool, u: Bool): Unit {
        out.write(reset.toUtf8())
        if (b) { out.write(boldStyle.toUtf8()) }
        if (i) { out.write(italic.toUtf8()) }
        if (u) { out.write(underline.toUtf8()) }
    }

    func emitInline(s: String, b: Bool, i: Bool, u: Bool): Unit {
        var pos: Int32 = 0
        var runStart: Int32 = 0
        sgr(b, i, u)
        let runes = s.toRuneArray()
        while (pos < runes.size) {
            if (runes[pos] == "`") {
                if (let (inner, n, ok) <- matchCode(runes, pos) {
                    emitText(String.fromRunes(runes.slice(runStart, pos)))
                    out.write(cyan.toUtf8())
                    emitText(String.fromRunes(runes.slice(inner[0], inner[1])))
                    out.write(reset.toUtf8())
                    sgr(b, i, u)
                    pos = inner[1] + n
                    runStart = inner[1] + n
                    continue
                }
            }
            if (runes[pos] == "[") {
                if (let (t, uu, ok) <- matchLink(runes, pos) {
                    emitText(String.fromRunes(runes.slice(runStart, pos)))
                    emitLink(runes, t, uu, b, i)
                    pos = uu[1] + 1
                    runStart = uu[1] + 1
                    continue
                }
            }
            if (runes[pos] == "*" || runes[pos] == "_") {
                if (let (isBold, inner, ok) <- matchEmph(runes, pos) {
                    emitText(String.fromRunes(runes.slice(runStart, pos)))
                    if (isBold) {
                        emitInline(String.fromRunes(runes.slice(inner[0], inner[1])), true, i, u)
                    } else {
                        emitInline(String.fromRunes(runes.slice(inner[0], inner[1])), b, true, u)
                    }
                    sgr(b, i, u)
                    if (isBold) {
                        pos = inner[1] + 2
                        runStart = inner[1] + 2
                    } else {
                        pos = inner[1] + 1
                        runStart = inner[1] + 1
                    }
                    continue
                }
            }
            pos++
        }
        emitText(String.fromRunes(runes.slice(runStart, pos)))
    }

    func emitLink(runes: Array<Rune>, t: (Int32, Int32), u: (Int32, Int32), b: Bool, i: Bool): Unit {
        out.write("\u001b]8;;".toUtf8())
        emitText(String.fromRunes(runes.slice(u[0], u[1])))
        out.write("\u001b\\".toUtf8())
        out.write((underline + cyan).toUtf8())
        emitInline(String.fromRunes(runes.slice(t[0], t[1])), b, i, false)
        out.write(reset.toUtf8())
        out.write("\u001b]8;;\u001b\\".toUtf8())
        sgr(b, i, false)
    }

    func matchCode(runes: Array<Rune>, pos: Int32): ?((Int32, Int32), Int32, Bool) {
        var n: Int32 = 0
        while (pos + n < runes.size && runes[pos + n] == "`") {
            n++
        }
        if (n == 0) { return None }
        var scan = pos + n
        while (scan < runes.size) {
            var k: Int32 = 0
            while (scan + k < runes.size && runes[scan + k] == "`") {
                k++
            }
            if (k == n) {
                return ((pos + n, scan), n, true)
            }
            if (k == 0) {
                scan++
            } else {
                scan += k
            }
        }
        None
    }

    func matchLink(runes: Array<Rune>, pos: Int32): ?((Int32, Int32), (Int32, Int32), Bool) {
        if (pos >= runes.size || runes[pos] != "[") { return None }
        var i = pos + 1
        while (i < runes.size && runes[i] != "]") {
            if (runes[i] == "[") { return None }
            i++
        }
        if (i >= runes.size || runes[i] != "]") { return None }
        let t = (pos + 1, i)
        i++
        if (i >= runes.size || runes[i] != "(") { return None }
        i++
        let st = i
        while (i < runes.size && runes[i] != ")") {
            i++
        }
        if (i >= runes.size || runes[i] != ")") { return None }
        (t, (st, i), true)
    }

    func matchEmph(runes: Array<Rune>, pos: Int32): ?(Bool, (Int32, Int32), Bool) {
        if (pos >= runes.size) { return None }
        let c = runes[pos]
        if (c != "*" && c != "_") { return None }
        let double = pos + 1 < runes.size && runes[pos + 1] == c
        var delim: Int32 = 2
        if (!double) { delim = 1 }
        var scan = pos + delim
        while (scan < runes.size) {
            if (runes[scan] == c) {
                let following = scan + 1 < runes.size && runes[scan + 1] == c
                if (double && following) {
                    return (true, (pos + 2, scan), true)
                }
                if (!double && !following) {
                    return (false, (pos + 1, scan), true)
                }
                if (double) {
                    scan++
                } else {
                    scan += 2
                }
            } else {
                scan++
            }
        }
        None
    }
}
