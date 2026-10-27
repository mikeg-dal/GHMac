import Foundation
import GHEKit

/// Everything a Device Manager row needs to build and run its device. Shared by all rows.
public struct DeviceEnvironment: Sendable {
    public var registry: DeviceRegistry
    public var portResolver: any PortResolver
    public var transportFactory: any TransportFactory
    public var clock: any GHEClock
    public var profiles: any WioProfileLookup
    public var switchState: any SwitchStatePersisting
    public var basePool: WIOBasePool
    public var rotorSources: RotorSourceDirectory
    /// RT-21 unit digit for poll/goto.
    public var rt21AddressDigit: Character

    public init(registry: DeviceRegistry, portResolver: any PortResolver, transportFactory: any TransportFactory,
                clock: any GHEClock = SystemClock(), profiles: any WioProfileLookup = StaticProfileLookup([]),
                switchState: any SwitchStatePersisting = InMemorySwitchStateStore(),
                basePool: WIOBasePool? = nil, rotorSources: RotorSourceDirectory = RotorSourceDirectory(),
                rt21AddressDigit: Character = "2") {
        self.registry = registry; self.portResolver = portResolver; self.transportFactory = transportFactory
        self.clock = clock; self.profiles = profiles; self.switchState = switchState
        self.basePool = basePool ?? WIOBasePool(clock: clock)
        self.rotorSources = rotorSources; self.rt21AddressDigit = rt21AddressDigit
    }
}

/// Events from a Device Manager row to its UI.
public enum SlotEvent: Sendable, Equatable {
    case status(SlotStatus)
    /// Fixed Antenna without a heading: ask "Enter heading for this fixed antenna:", then
    /// `setFixedHeading(_:)` and `connect()` again.
    case needsFixedHeading(previous: Double?)
    /// Cloned Antenna without a valid offset: ask "Enter offset for this Cloned antenna (+/- 180.0):".
    case needsCloneOffset(previous: Double?)
}

/// Runs the device of one Device Manager row.
///
/// * Port `N/A` is rejected instead of looping in Retrying.
/// * Configuration and open errors are shown as `.error(message)`; only a lost link retries.
/// * Cable pull: serial (and simulated) ports are retried every 1 s once the port is listed again;
///   TCP endpoints back off from `Timing.tcpReconnectMinimum` to `…Maximum`. Attempts never overlap.
/// * Disconnecting keeps the fixed heading and clone offset.
public actor DeviceSlotController {
    private enum Active {
        case rotor(any RotorDriver, sourceKey: String?, fanout: EventBroadcaster<RotorReading>)
        case switchDevice(WIOSwitch)
        case stack(WIOStackMatch)
    }

    private enum Outcome {
        case started
        case prompt
        /// Configuration problem: show it, don't retry.
        case failure(String)
        /// The port, link or source isn't there right now: retryable after a cable pull.
        case unavailable(String, isTCP: Bool)
    }

    public nonisolated let events = EventBroadcaster<SlotEvent>()
    public private(set) var config: DevicePanelConfig
    public private(set) var status: SlotStatus = .disconnected
    private let env: DeviceEnvironment
    private var active: Active?
    private var pumpTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var wantConnected = false

    public init(config: DevicePanelConfig, environment: DeviceEnvironment) {
        self.config = config
        self.env = environment
    }

    /// Replaces the row's configuration (takes effect on the next connect).
    public func update(config: DevicePanelConfig) { self.config = config }
    public func setFixedHeading(_ h: Double) { config.fixedHeading = h }
    public func setCloneOffset(_ o: Double) { config.cloneOffset = o }

    public var isRetrying: Bool { retryTask != nil }

    /// The user pressed the toggle (or auto-connect at startup).
    public func connect() async {
        switch status {
        case .disconnected, .error: break
        default: return
        }
        generation += 1
        wantConnected = true
        let gen = generation
        switch await attempt(gen) {
        case .started:
            break
        case .prompt:
            wantConnected = false
            setStatus(.disconnected)
        case .failure(let msg):
            wantConnected = false
            setStatus(.error(msg))
        case .unavailable(let msg, let isTCP):
            if isTCP {
                // A TCP rotor/Base that is offline at connect time is retried with backoff.
                setStatus(.error(msg))
                startRetry(gen)
            } else {
                wantConnected = false
                setStatus(.error(msg))
            }
        }
    }

    /// The user released the toggle: stop retrying, close the device, REMOVE it.
    public func disconnect() async {
        wantConnected = false
        generation += 1
        retryTask?.cancel(); retryTask = nil
        pumpTask?.cancel(); pumpTask = nil
        await teardown()
        setStatus(.disconnected)
    }

    // MARK: - Connect

    private func attempt(_ gen: Int) async -> Outcome {
        let cfg = config
        guard !cfg.name.isEmpty else { return .failure("You must supply a name for this device.") }
        guard let type = cfg.type else { return .failure("Unknown device type \(cfg.deviceType).") }
        let port = cfg.port.replacingOccurrences(of: "*", with: "")
        let hasPort = !port.isEmpty && port != DevicePanelConfig.notApplicable

        switch type {
        case .fixedAntenna:
            guard let h = cfg.fixedHeading, h != DevicePanelConfig.fixedHeadingUnset, h.isFinite else {
                events.yield(.needsFixedHeading(previous: nil))
                return .prompt
            }
            setStatus(.connecting)
            return await startRotor(FixedRotor(name: cfg.name, heading: h, clock: env.clock), sourceKey: nil, gen: gen)

        case .rt21, .dcu1:
            guard hasPort else { return .failure("You must supply a port for this device.") }
            guard let ep = env.portResolver.endpoint(for: port, settings: .rotor) else {
                return .unavailable("Port \(port) is not available.", isTCP: false)
            }
            let transport = env.transportFactory.make(ep)
            let driver: any RotorDriver = type == .rt21
                ? RT21Driver(name: cfg.name, transport: transport, clock: env.clock, addressDigit: env.rt21AddressDigit)
                : DCU1Driver(name: cfg.name, transport: transport, clock: env.clock)
            setStatus(.connecting)
            let outcome = await startRotor(driver, sourceKey: RotorSourceDirectory.directKey(port: port), gen: gen,
                                           isTCP: ep.isTCP)
            if case .started = outcome { Task { await driver.query() } }   // connect query
            return outcome

        case .clonedAntenna:
            guard let off = cfg.cloneOffset, off != DevicePanelConfig.cloneOffsetUnset, (-180...180).contains(off) else {
                events.yield(.needsCloneOffset(previous: nil))
                return .prompt
            }
            var src = await env.rotorSources.source(RotorSourceDirectory.directKey(port: port))
            if src == nil, let a = cfg.wioAddress {
                src = await env.rotorSources.source(RotorSourceDirectory.wioKey(port: port, address: a))
            }
            guard let src else {
                return .unavailable("Port \(port) does not have a rotor connected to it.\n Did you forget to specify an address for a WIO rotor?", isTCP: false)
            }
            setStatus(.connecting)
            let clone = ClonedRotor(name: cfg.name, offset: off, source: src.driver, sourceReadings: src.readings.subscribe())
            let outcome = await startRotor(clone, sourceKey: nil, gen: gen)
            if case .started = outcome { Task { await clone.query() } }
            return outcome

        case .gheBase, .virtualSwitch:
            return await startWIO(cfg, type: type, port: port, hasPort: hasPort, gen: gen)
        }
    }

    private func startWIO(_ cfg: DevicePanelConfig, type: DeviceType, port: String, hasPort: Bool, gen: Int) async -> Outcome {
        guard hasPort else { return .failure("You must supply a port for this device.") }
        let sub = cfg.subType
        guard sub != DevicePanelConfig.notApplicable, !sub.isEmpty else { return .failure("You must select a WIO subtype.") }
        let address = type == .virtualSwitch ? 0 : cfg.wioAddress
        guard let address, (0...255).contains(address) else { return .failure("You must select a WIO address.") }

        enum Kind { case rotor, stack(WIOStackType), profile(WioProfile) }
        let kind: Kind
        if type == .gheBase && sub == WIOSubtypes.rt21 {
            kind = .rotor
        } else if type == .gheBase, let st = WIOStackType(subTypeName: sub) {
            kind = .stack(st)
        } else if let p = await env.profiles.profile(named: sub) {
            kind = .profile(p)
        } else {
            // An unknown subtype is reported instead of leaving the toggle stuck.
            return .failure("Unknown WIO subtype \(sub).")
        }

        let settings = SerialSettings(baud: SerialSettings.wioBase.baud, flow: cfg.basePTT ? .rtsCts : .none)
        guard let ep = env.portResolver.endpoint(for: port, settings: settings) else {
            return .unavailable("Port \(port) is not available.", isTCP: false)
        }
        setStatus(.validating)
        let factory = env.transportFactory
        let base: WIOBase
        do {
            base = try await env.basePool.base(portName: port, basePTT: cfg.basePTT, makeTransport: { factory.make(ep) })
        } catch let e as WIOBaseError {
            return .failure(e.localizedDescription)
        } catch {
            return .unavailable(Self.describe(error), isTCP: ep.isTCP)
        }
        guard gen == generation else { return .failure("Cancelled.") }
        let remote = await base.physicalRemote(address: address)

        switch kind {
        case .rotor:
            let r = WIORotor(name: cfg.name, remote: remote, clock: env.clock)
            return await startRotor(r, sourceKey: RotorSourceDirectory.wioKey(port: port, address: address), gen: gen,
                                    isTCP: ep.isTCP, keepStatus: true)
        case .stack(let st):
            let registry = env.registry
            let stack = WIOStackMatch(name: cfg.name, type: st, remote: remote,
                                      isRotorConnected: { await registry.isRotorConnected($0) })
            await registry.registerStack(stack)
            let updates = await stack.start()
            active = .stack(stack)
            pumpTask = Task { [weak self] in
                for await u in updates {
                    if u.status == 0 { await self?.markConnected(gen) }
                    await registry.stackUpdate(u, from: stack)
                }
                await self?.deviceEnded(gen)
            }
            return .started
        case .profile(let p):
            let registry = env.registry
            let sw = WIOSwitch(name: cfg.name, profile: p, remote: remote, persistence: env.switchState)
            await registry.registerSwitch(sw)
            let updates = await sw.start()
            active = .switchDevice(sw)
            pumpTask = Task { [weak self] in
                for await u in updates {
                    if u.status == 0 { await self?.markConnected(gen) }
                    await registry.switchUpdate(u, from: sw)
                }
                await self?.deviceEnded(gen)
            }
            return .started
        }
    }

    private func startRotor(_ driver: any RotorDriver, sourceKey: String?, gen: Int, isTCP: Bool = false,
                            keepStatus: Bool = false) async -> Outcome {
        let stream: AsyncStream<RotorReading>
        do { stream = try await driver.start() } catch {
            return .unavailable(Self.describe(error), isTCP: isTCP)
        }
        let fanout = EventBroadcaster<RotorReading>()
        if let sourceKey { await env.rotorSources.register(sourceKey, driver: driver, readings: fanout) }
        active = .rotor(driver, sourceKey: sourceKey, fanout: fanout)
        let registry = env.registry
        pumpTask = Task { [weak self] in
            for await r in stream {
                await self?.markConnected(gen)
                await registry.rotorReading(r, from: driver)
                fanout.yield(r)
            }
            await self?.deviceEnded(gen)
        }
        return .started
    }

    // MARK: - Running

    private func markConnected(_ gen: Int) {
        guard gen == generation, wantConnected, status != .connected else { return }
        retryTask = nil
        setStatus(.connected)
    }

    /// The device's stream ended. If the user didn't ask for it, that's a cable pull.
    private func deviceEnded(_ gen: Int) async {
        guard gen == generation, wantConnected else { return }
        setStatus(.error("Connection lost"))
        await teardown()
        startRetry(gen)
    }

    private func teardown() async {
        guard let a = active else { return }
        active = nil
        let registry = env.registry
        switch a {
        case .rotor(let d, let key, let fanout):
            await d.close()
            await registry.removeRotor(d)
            if let key { await env.rotorSources.unregister(key, driver: d) }
            fanout.finish()
        case .switchDevice(let sw):
            await sw.close()
            await registry.removeSwitch(sw)
        case .stack(let st):
            await st.close()
            await registry.removeStack(st)
        }
    }

    // MARK: - Retry

    private func startRetry(_ gen: Int) {
        retryTask?.cancel()
        setStatus(.retrying)
        let clock = env.clock
        retryTask = Task { [weak self] in
            var tcpDelay = Timing.tcpReconnectMinimum
            while !Task.isCancelled {
                guard let self else { return }
                let isTCP = await self.endpointIsTCP()
                let delay = isTCP ? tcpDelay : Timing.cablePullRetryPeriod
                do { try await clock.sleep(for: delay) } catch { return }
                guard await self.portIsListed() else { continue }
                switch await self.retryOnce(gen) {
                case .done: return
                case .again:
                    if isTCP { tcpDelay = min(tcpDelay * 2, Timing.tcpReconnectMaximum) }
                }
            }
        }
    }

    private enum RetryStep { case done, again }

    private func retryOnce(_ gen: Int) async -> RetryStep {
        guard gen == generation, wantConnected else { return .done }
        switch await attempt(gen) {
        case .started:
            retryTask = nil
            if status == .retrying { setStatus(.connecting) }
            return .done
        case .prompt:
            wantConnected = false
            retryTask = nil
            setStatus(.disconnected)
            return .done
        case .failure(let msg):
            wantConnected = false
            retryTask = nil
            setStatus(.error(msg))
            return .done
        case .unavailable:
            setStatus(.retrying)
            return .again
        }
    }

    private func endpointIsTCP() -> Bool {
        let port = config.port.replacingOccurrences(of: "*", with: "")
        return env.portResolver.endpoint(for: port, settings: .rotor)?.isTCP ?? false
    }

    /// Serial ports must be enumerated again before a reopen; TCP and clones skip this.
    private func portIsListed() -> Bool {
        if config.type == .clonedAntenna || endpointIsTCP() { return true }
        let port = config.port.replacingOccurrences(of: "*", with: "")
        return env.portResolver.portNames().contains(port)
    }

    private func setStatus(_ s: SlotStatus) {
        guard s != status else { return }
        status = s
        events.yield(.status(s))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

extension Endpoint {
    var isTCP: Bool { if case .tcp = self { true } else { false } }
}
