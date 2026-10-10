// Error code contract for the entire project.
package cpi.internal.apperr

public class CodedError <: Exception {
    public let code: Int32

    public init(code: Int32, message: String) {
        super(message)
        this.code = code
    }

    public func getCode(): Int32 { code }
}

public func fail(code: Int32, format: String, args: Array<Any>): CodedError {
    CodedError(code, format)
}

public func wrapErr(code: Int32, err: Exception): CodedError {
    CodedError(code, err.message)
}

public func exitCodeOf(err: ?Exception): Int32 {
    match (err) {
        case Some(e) =>
            if (let coded: CodedError <- e) {
                coded.getCode()
            } else {
                1
            }
        case None => 1
    }
}
