import Darwin
import WebKit

/// A page process still running flat out after its tab let it go (from
/// upstream Search, #1468).
///
/// Closing or sleeping a tab drops its view, and WebKit then asks the page's
/// process to wind down. A process whose main thread never comes back to
/// hear that keeps going with no tab left to show it — WebKit's
/// accessibility updates can loop like that once anything on the Mac reads
/// the screen through Accessibility (a window manager, a password app), and
/// Safari does the same on the same pages. What Browser can do is not leave
/// it burning a core all night.
///
/// Ten seconds after the view goes, the process is looked at once. Only one
/// that spent most of that time on the CPU, that is still a WebKit page
/// process, and that no other view of Browser's still uses is ended. An idle
/// one WebKit keeps for reuse is left alone.
@MainActor
enum Stuck {
    static let wait: TimeInterval = 10
    /// Share of one core that counts as stuck over `wait`.
    static let busy = 0.8

    private static let key = "_webProcessIdentifier"

    static func watch(_ web: WKWebView) {
        guard let pid = process(of: web), let start = cpu(pid) else { return }
        weak let gone = web
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated {
                guard let end = cpu(pid), end >= start,
                      Double(end - start) / 1e9 >= wait * busy,
                      isPage(pid) else { return }
                // A page a link opened can share its opener's process; that
                // one is still somebody's.
                let views = Browser.every.allObjects.flatMap { $0.tabs.compactMap(\.built) }
                guard !views.contains(where: { $0 !== gone && process(of: $0) == pid }) else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    private static func process(of web: WKWebView) -> pid_t? {
        guard web.responds(to: NSSelectorFromString(key)),
              let pid = web.value(forKey: key) as? Int, pid > 0 else { return nil }
        return pid_t(pid)
    }

    /// CPU time the process has used, in nanoseconds. The kernel counts it
    /// in Mach ticks, which on Apple silicon aren't nanoseconds.
    private static func cpu(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard read == 0 else { return nil }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        guard base.denom > 0 else { return nil }
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        return ticks.multipliedReportingOverflow(by: UInt64(base.numer)).partialValue / UInt64(base.denom)
    }

    /// The number could have gone to another process meanwhile: end only a
    /// WebKit page process.
    private static func isPage(_ pid: pid_t) -> Bool {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return false }
        return String(decoding: path.prefix(Int(length)), as: UTF8.self).hasSuffix("/com.apple.WebKit.WebContent")
    }
}
