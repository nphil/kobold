import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func post(_ label: String) async {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:8799/mytopic")!)
    r.httpMethod = "POST"; r.httpBody = Data("hello".utf8); r.timeoutInterval = 10
    do {
        let (_, resp) = try await URLSession.shared.data(for: r)
        print("\(label): SUCCESS \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
    } catch {
        print("\(label): FAILURE \(error)")
    }
}

@main struct M {
    static func main() async {
        // control: not cancelled
        await Task { await post("not-cancelled") }.value
        // the NtfySink timer path: task cancels itself, then calls URLSession
        let t = Task { @Sendable () async -> Void in
            // simulate `flushTask?.cancel()` where flushTask === self
            print("self-cancelled task: isCancelled before post = \(Task.isCancelled)")
            await post("self-cancelled")
        }
        t.cancel()
        await t.value
        // also verify URL(string:relativeTo:) resolution used at NtfySink.swift:180
        print("resolved:", URL(string: "kobold-abc123", relativeTo: URL(string: "https://ntfy.sh")!)!.absoluteString)
        print("resolved w/ slash:", URL(string: "kobold-abc123", relativeTo: URL(string: "https://ntfy.sh/")!)!.absoluteString)
    }
}
