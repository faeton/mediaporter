// One-shot ready gate per file used by the pipelined transcode + upload
// flow. The transcode side `fire()`s when ffmpeg finishes (or fails) for
// the file; the upload side `wait()`s on the same gate before pushing
// bytes. Lets transcodes run a bounded number of steps ahead of uploads
// without blowing up temp disk usage.
//
// Why not a `Task` directly: we want to spawn transcode work in a single
// TaskGroup gated by a concurrency limit (so 24 ffmpeg processes don't
// stampede the HW media engine + temp disk), but the upload loop still
// needs to await each file in input order. Re-mapping "task that finished
// 3rd in arrival order → file at position 0" is fiddly; per-file gates
// keep input order trivial.

import Foundation

actor TranscodeReadyGate {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        if let cont = waiter {
            waiter = nil
            cont.resume()
        }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiter = cont
        }
    }
}
