#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension String {
    static func readPassword() -> String {
        #if canImport(Darwin)
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
            print()
        }
        #endif

        return readLine(strippingNewline: true) ?? ""
    }
}
