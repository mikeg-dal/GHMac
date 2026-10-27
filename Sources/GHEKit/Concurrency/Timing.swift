import Foundation

/// Every timer constant, in one place.
public enum Timing {
    // MARK: Client ⇄ Server
    /// First keepalive NUL after connect.
    public static let keepaliveInitialDelay: Duration = .seconds(10)
    /// Keepalive NUL period.
    public static let keepalivePeriod: Duration = .seconds(5)
    /// Client "Retrying" reconnect delay.
    public static let clientRetryDelay: Duration = .seconds(15)
    /// Server closes a connection that hasn't authenticated within this time of `USER:`.
    public static let authTimeout: Duration = .seconds(5)
    /// Swift client: hold outbound commands after sending the digest until a line arrives or this passes.
    public static let postAuthHold: Duration = .milliseconds(250)

    // MARK: Rotor drivers
    /// RT-21 / DCU-1 direct poll: first poll after this delay…
    public static let rotorPollInitialDelay: Duration = .seconds(2)
    /// …then every period.
    public static let rotorPollPeriod: Duration = .seconds(1)
    /// Unanswered polls before status '5' (strictly greater than this).
    public static let rotorMaxMissedPolls = 5
    /// WIO remote rotor poll cycle (2 × 400 ms).
    public static let wioRotorPollPeriod: Duration = .milliseconds(800)
    /// WIO goto/stop are sent 3 times this far apart.
    public static let wioRepeatSpacing: Duration = .milliseconds(500)
    public static let wioRepeatCount = 3
    /// Fixed antenna status event period.
    public static let fixedRotorPeriod: Duration = .seconds(2)
    /// Client terminal-server (direct RT-21) poll period.
    public static let terminalServerPollPeriod: Duration = .seconds(1)

    // MARK: WIO / XBee
    public static let wioBaseValidateWait: Duration = .seconds(3)
    public static let wioRemotePollInitialDelay: Duration = .seconds(2)
    public static let wioRemoteCycle: Duration = .milliseconds(800)
    public static let wioRemoteHalfCycle: Duration = .milliseconds(400)
    /// DB (RSSI) query every Nth remote cycle.
    public static let wioRSSIEveryNthCycle = 5
    /// Momentary relay pulse length.
    public static let wioMomentaryPulse: Duration = .milliseconds(500)
    /// Remote "no response" (status 4) reported only after more than this many in a row.
    public static let wioNoResponseDebounce = 10
    /// Switch/stack updates are re-broadcast at least every Nth response.
    public static let wioUpdateEveryNthResponse = 5

    // MARK: Server device manager
    public static let cablePullRetryPeriod: Duration = .seconds(1)
    /// TCP rotor reconnect backoff.
    public static let tcpReconnectMinimum: Duration = .seconds(5)
    public static let tcpReconnectMaximum: Duration = .seconds(60)

    // MARK: Client UI
    /// Jog clicks within this window accumulate; Turn fires this long after the last click.
    public static let jogDebounce: Duration = .seconds(1)
    /// TURN_CW/TURN_CCW hotkey lockout.
    public static let turnHotkeyLockout: Duration = .milliseconds(500)
    /// Stack-match widget watchdog.
    public static let stackWatchdogFirst: Duration = .seconds(5)
    public static let stackWatchdogSecond: Duration = .seconds(8)

    // MARK: Client integrations
    public static let n3fjpReconnectDelay: Duration = .seconds(1)
    public static let phidgetLongPress: Duration = .milliseconds(1500)
}
