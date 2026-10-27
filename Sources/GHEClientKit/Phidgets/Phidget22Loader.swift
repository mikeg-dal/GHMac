import Darwin
import Foundation
import os
import Security

/// Phidget22 C entry points, resolved with `dlsym` (no headers or module map).
/// Signatures follow phidget22.h (PhidgetReturnCode is a C enum = Int32; 0 = EPHIDGET_OK).
public struct Phidget22API: @unchecked Sendable {
    public typealias Handle = OpaquePointer
    public typealias ReturnCode = Int32

    public typealias OpenFn = @convention(c) (Handle?) -> ReturnCode
    public typealias OpenWaitFn = @convention(c) (Handle?, UInt32) -> ReturnCode
    public typealias CloseFn = @convention(c) (Handle?) -> ReturnCode
    public typealias DeleteFn = @convention(c) (UnsafeMutablePointer<Handle?>?) -> ReturnCode
    public typealias CreateFn = @convention(c) (UnsafeMutablePointer<Handle?>?) -> ReturnCode
    public typealias GetIntFn = @convention(c) (Handle?, UnsafeMutablePointer<Int32>?) -> ReturnCode
    public typealias SetIntFn = @convention(c) (Handle?, Int32) -> ReturnCode
    public typealias SetUIntFn = @convention(c) (Handle?, UInt32) -> ReturnCode

    /// `PhidgetEncoder_OnPositionChangeCallback(ch, ctx, positionChange, timeChange, indexTriggered)`.
    public typealias PositionChangeCallback = @convention(c) (Handle?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    public typealias SetPositionHandlerFn = @convention(c) (Handle?, PositionChangeCallback?, UnsafeMutableRawPointer?) -> ReturnCode
    /// `PhidgetDigitalInput_OnStateChangeCallback(ch, ctx, state)`.
    public typealias StateChangeCallback = @convention(c) (Handle?, UnsafeMutableRawPointer?, Int32) -> Void
    public typealias SetStateHandlerFn = @convention(c) (Handle?, StateChangeCallback?, UnsafeMutableRawPointer?) -> ReturnCode
    /// `PhidgetManager_OnAttachCallback(manager, ctx, channel)` (detach has the same shape).
    public typealias ManagerCallback = @convention(c) (Handle?, UnsafeMutableRawPointer?, Handle?) -> Void
    public typealias SetManagerHandlerFn = @convention(c) (Handle?, ManagerCallback?, UnsafeMutableRawPointer?) -> ReturnCode

    public var open: OpenFn
    public var openWaitForAttachment: OpenWaitFn
    public var close: CloseFn
    public var delete: DeleteFn
    public var getDeviceSerialNumber: GetIntFn
    public var setDeviceSerialNumber: SetIntFn
    public var getChannelClass: GetIntFn
    public var getChannel: GetIntFn
    public var setChannel: SetIntFn
    public var encoderCreate: CreateFn
    public var encoderSetOnPositionChangeHandler: SetPositionHandlerFn
    public var encoderSetDataInterval: SetUIntFn?
    public var digitalInputCreate: CreateFn
    public var digitalInputSetOnStateChangeHandler: SetStateHandlerFn
    public var managerCreate: CreateFn
    public var managerDelete: DeleteFn
    public var managerOpen: OpenFn
    public var managerClose: CloseFn
    public var managerSetOnAttachHandler: SetManagerHandlerFn
    public var managerSetOnDetachHandler: SetManagerHandlerFn

    /// `Phidget_ChannelClass` values used here.
    public static let channelClassDigitalInput: Int32 = 0x5
    public static let channelClassEncoder: Int32 = 0x8
    public static let ok: ReturnCode = 0
}

public enum Phidget22LoadError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case invalidSignature(String)
    case dlopenFailed(String)
    case missingSymbol(String)

    public var description: String {
        switch self {
        case .notInstalled: "Phidget22 is not installed."
        case .invalidSignature(let why): "Phidget22.framework failed its code-signature check: \(why)"
        case .dlopenFailed(let why): "Could not load Phidget22: \(why)"
        case .missingSymbol(let s): "Phidget22 is missing \(s)."
        }
    }
}

/// Loads the system Phidget22 framework if (and only if) it is installed and validly signed.
/// The app builds and runs without it (`isAvailable == false`).
public enum Phidget22Loader {
    public static let frameworkPath = "/Library/Frameworks/Phidget22.framework"
    public static let binaryPath = frameworkPath + "/Phidget22"
    /// Phidgets Inc. Developer ID team.
    public static let phidgetsTeamID = "L789APR8K7"
    /// Developer ID–anchored and issued to Phidgets Inc.
    public static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(phidgetsTeamID)\""

    private static let log = Logger(subsystem: "com.mikegarcia.GHEClientKit", category: "Phidget22")

    /// Result of the one-time load.
    public static let shared: Result<Phidget22API, Phidget22LoadError> = load()

    public static var isAvailable: Bool { (try? shared.get()) != nil }

    /// Verifies the bundle's signature, then `dlopen`s the fixed system path.
    public static func load(frameworkPath: String = frameworkPath, binaryPath: String = binaryPath,
                            requirement: String = requirement) -> Result<Phidget22API, Phidget22LoadError> {
        guard FileManager.default.fileExists(atPath: binaryPath) else { return .failure(.notInstalled) }
        if let problem = signatureProblem(path: frameworkPath, requirement: requirement) {
            log.error("Refusing to load Phidget22: \(problem, privacy: .public)")
            return .failure(.invalidSignature(problem))
        }
        guard let lib = dlopen(binaryPath, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "unknown error"
            log.error("dlopen Phidget22 failed: \(why, privacy: .public)")
            return .failure(.dlopenFailed(why))
        }
        do {
            func sym<T>(_ name: String, _: T.Type) throws -> T {
                guard let p = dlsym(lib, name) else { throw Phidget22LoadError.missingSymbol(name) }
                return unsafeBitCast(p, to: T.self)
            }
            let api = Phidget22API(
                open: try sym("Phidget_open", Phidget22API.OpenFn.self),
                openWaitForAttachment: try sym("Phidget_openWaitForAttachment", Phidget22API.OpenWaitFn.self),
                close: try sym("Phidget_close", Phidget22API.CloseFn.self),
                delete: try sym("Phidget_delete", Phidget22API.DeleteFn.self),
                getDeviceSerialNumber: try sym("Phidget_getDeviceSerialNumber", Phidget22API.GetIntFn.self),
                setDeviceSerialNumber: try sym("Phidget_setDeviceSerialNumber", Phidget22API.SetIntFn.self),
                getChannelClass: try sym("Phidget_getChannelClass", Phidget22API.GetIntFn.self),
                getChannel: try sym("Phidget_getChannel", Phidget22API.GetIntFn.self),
                setChannel: try sym("Phidget_setChannel", Phidget22API.SetIntFn.self),
                encoderCreate: try sym("PhidgetEncoder_create", Phidget22API.CreateFn.self),
                encoderSetOnPositionChangeHandler: try sym("PhidgetEncoder_setOnPositionChangeHandler",
                                                           Phidget22API.SetPositionHandlerFn.self),
                encoderSetDataInterval: try? sym("PhidgetEncoder_setDataInterval", Phidget22API.SetUIntFn.self),
                digitalInputCreate: try sym("PhidgetDigitalInput_create", Phidget22API.CreateFn.self),
                digitalInputSetOnStateChangeHandler: try sym("PhidgetDigitalInput_setOnStateChangeHandler",
                                                             Phidget22API.SetStateHandlerFn.self),
                managerCreate: try sym("PhidgetManager_create", Phidget22API.CreateFn.self),
                managerDelete: try sym("PhidgetManager_delete", Phidget22API.DeleteFn.self),
                managerOpen: try sym("PhidgetManager_open", Phidget22API.OpenFn.self),
                managerClose: try sym("PhidgetManager_close", Phidget22API.CloseFn.self),
                managerSetOnAttachHandler: try sym("PhidgetManager_setOnAttachHandler",
                                                   Phidget22API.SetManagerHandlerFn.self),
                managerSetOnDetachHandler: try sym("PhidgetManager_setOnDetachHandler",
                                                   Phidget22API.SetManagerHandlerFn.self))
            return .success(api)
        } catch let e as Phidget22LoadError {
            dlclose(lib)
            log.error("\(e.description, privacy: .public)")
            return .failure(e)
        } catch {
            dlclose(lib)
            return .failure(.dlopenFailed("\(error)"))
        }
    }

    /// nil if the bundle at `path` is validly signed and meets `requirement`; else a reason.
    public static func signatureProblem(path: String, requirement: String) -> String? {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return "cannot read code (\(status))" }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard status == errSecSuccess, let req else { return "bad requirement (\(status))" }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req)
        guard status == errSecSuccess else {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return "\(msg) (\(status))"
        }
        return nil
    }
}
