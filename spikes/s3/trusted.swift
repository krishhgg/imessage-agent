import ApplicationServices
import Foundation
typealias RespFn = @convention(c) (pid_t) -> pid_t
let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")!
let rp = unsafeBitCast(sym, to: RespFn.self)(getpid())
var buf = [CChar](repeating: 0, count: 4096); proc_pidpath(rp, &buf, 4096)
print("ax_trusted=\(AXIsProcessTrusted()) responsible=\(String(cString: buf))")
