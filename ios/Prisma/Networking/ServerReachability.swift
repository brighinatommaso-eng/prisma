import Foundation
import Network
import Observation

/// Whether the Prisma backend answers right now. One answer, in one place.
///
/// "Online" is not the question. A phone with full signal and the server switched
/// off is online; hotel wifi that blocks Tailscale is online; mobile data with the
/// server behind a LAN address is online. None of those can stream. The only honest
/// test is to ask the server itself, so this asks `GET /health` and reports what
/// came back.
///
/// It is not a poll. Nothing here schedules repeated work: every probe is the
/// consequence of something that happened — the network path changed, the app came
/// back to the foreground, the server address was saved, or a stream just failed.
/// Between events the last answer stands, and inside `freshFor` seconds of a
/// completed probe an unforced request is answered from that answer instead of
/// asking again, and a request arriving while one is already in flight is dropped
/// rather than duplicating it.
///
/// The interface never waits on it. Screens read `isReachable` as it is, and
/// playback treats "not yet known" as "try, and let the attempt say" — which is why
/// a slow probe can never become a spinner.
@Observable
final class ServerReachability {
    /// nil until the first probe finishes: nothing has asked the server yet.
    private(set) var isReachable: Bool?
    /// When the last probe finished, successful or not.
    private(set) var checkedAt: Date?
    /// Why the last probe failed, with everything needed to read it on screen.
    private(set) var lastProblem: APIError?
    /// True while a probe is in flight, so Impostazioni can say so.
    private(set) var isProbing = false

    /// How long a finished answer is reused before an unforced request asks again.
    /// Long enough that returning to the app twice in a row costs one request,
    /// short enough that the answer is never stale by more than a glance.
    static let freshFor: TimeInterval = 20

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var current: Task<Void, Never>?
    /// Bumped whenever a probe is started or thrown away, so a late answer from a
    /// superseded one is recognised and dropped.
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var monitor: NWPathMonitor?
    /// The last path iOS described, so a repeated identical update is not an event.
    @ObservationIgnored private var lastPathSummary: String?

    /// Called after the answer changes, with the new one. `AppModel` points this at
    /// `PlaybackEngine`, so the queue follows availability without the engine having
    /// to ask.
    @ObservationIgnored var onChange: ((_ reachable: Bool) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Starts watching the network path. Its first update arrives immediately, which
    /// is what performs the first probe of the process — no launch-time timer.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        ReachabilityBridge.watch(monitor) { [self] summary, satisfied in
            pathChanged(summary: summary, satisfied: satisfied)
        }
    }

    // MARK: - Events that make a probe happen

    /// The network path changed: a different interface, or none at all. A path that
    /// cannot carry traffic answers the question without a request; any other change
    /// invalidates the previous answer, so the server is asked again.
    private func pathChanged(summary: String, satisfied: Bool) {
        guard summary != lastPathSummary else { return }
        lastPathSummary = summary
        guard satisfied else {
            discardProbe()
            settle(
                reachable: false,
                problem: APIError(
                    kind: .transport,
                    title: "No usable network",
                    url: nil,
                    details: ["NWPathMonitor reports the path as \(summary)."],
                    message: "Questo telefono non ha una rete utilizzabile, quindi il server non è raggiungibile: si possono riprodurre solo i brani scaricati."
                )
            )
            return
        }
        probe(force: true)
    }

    /// The app came back to the foreground. Unforced: coming back twice within the
    /// freshness window costs one request.
    func appBecameActive() {
        probe(force: false)
    }

    /// A different server address was saved: the previous answer was about a
    /// different server and means nothing now.
    func addressChanged() {
        discardProbe()
        isReachable = nil
        checkedAt = nil
        lastProblem = nil
        probe(force: true)
    }

    /// A stream stalled, timed out or failed. The answer on file said reachable and
    /// the attempt disagreed, so it is asked again at once.
    func streamingFailed() {
        probe(force: true)
    }

    /// The user asked directly, e.g. by tapping a track that says the server is away.
    func retry() {
        probe(force: true)
    }

    // MARK: - Probing

    /// Asks the server, unless a recent answer still stands or a probe is already
    /// running. Returns immediately; the answer arrives in `isReachable`.
    ///
    /// `force` is for the events that make the previous answer meaningless — a
    /// different network, a different address, a stream that just contradicted it,
    /// or the user asking. Everything else respects `freshFor`.
    func probe(force: Bool) {
        if current != nil { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < Self.freshFor { return }
        probeGeneration += 1
        let generation = probeGeneration
        isProbing = true
        current = Task {
            await run(generation: generation)
            // A probe discarded while it was in flight must not clear the one that
            // replaced it.
            guard generation == probeGeneration else { return }
            isProbing = false
            current = nil
        }
    }

    /// Throws away whatever is in flight: it was asking about a different server,
    /// or over a network that has gone.
    private func discardProbe() {
        probeGeneration += 1
        current?.cancel()
        current = nil
        isProbing = false
    }

    private func run(generation: Int) async {
        do {
            let client = try settings.makeClient()
            _ = try await client.ping()
            guard generation == probeGeneration else { return }
            settle(reachable: true, problem: nil)
        } catch {
            let problem = APIError.from(error)
            // A cancelled or superseded probe answers nothing: whatever replaced it
            // is asking its own question, and recording "cancelled" as an answer
            // would make the interface flicker for no reason.
            guard generation == probeGeneration, !problem.isCancellation, !Task.isCancelled else { return }
            settle(reachable: false, problem: problem)
        }
    }

    /// Records an answer and tells whoever is listening, but only when it is news.
    private func settle(reachable: Bool, problem: APIError?) {
        let changed = isReachable != reachable
        isReachable = reachable
        checkedAt = Date()
        lastProblem = problem
        if changed {
            onChange?(reachable)
        }
    }

    // MARK: - For screens

    /// One line about the server, in the app's voice.
    var statusLine: String {
        if isProbing, isReachable == nil {
            return "Controllo del server in corso…"
        }
        switch isReachable {
        case nil:
            return "Il server non è ancora stato contattato in questa sessione."
        case true?:
            let when = checkedAt.map { " (controllato alle " + Formatting.time($0) + ")" } ?? ""
            return "Server raggiungibile: i brani che sono solo sul server si possono ascoltare in streaming" + when + "."
        case false?:
            let why = lastProblem.map { " " + PlainLanguage.message(for: $0) } ?? ""
            return "Server non raggiungibile: si possono riprodurre solo i brani scaricati sul telefono." + why
        }
    }

    /// Streaming is worth attempting: either the server answered, or nothing has
    /// asked yet and the attempt itself is the fastest way to find out.
    var mayStream: Bool {
        isReachable != false
    }
}

/// Forms the `NWPathMonitor` callback outside any actor and hands each update to the
/// main actor, for the same reason `PlaybackBridge` exists: a closure written inside
/// a main-actor type inherits that isolation, and `NWPathMonitor` calls its handler
/// on the queue it was given, which traps at runtime on a device with nothing on
/// screen to say why.
nonisolated enum ReachabilityBridge {
    static func watch(
        _ monitor: NWPathMonitor,
        _ handler: @escaping @MainActor @Sendable (_ summary: String, _ satisfied: Bool) -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let summary = describe(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handler(summary, satisfied)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.brighina.prisma.reachability"))
    }

    /// Enough of the path to tell one from another, and to read in an error report.
    private static func describe(_ path: NWPath) -> String {
        var parts: [String] = ["status=\(path.status)"]
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("ethernet") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        parts.append("interfaces=" + (interfaces.isEmpty ? "none" : interfaces.joined(separator: "+")))
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: " ")
    }
}
