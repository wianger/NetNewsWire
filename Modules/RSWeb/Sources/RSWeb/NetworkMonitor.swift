//
//  NetworkMonitor.swift
//  RSWeb
//
//  Created by Brent Simmons on 11/4/25.
//

import Foundation
#if canImport(Network)
import Network
#elseif os(Windows)
import WinSDK
#endif
import Synchronization

extension Notification.Name {
	/// Posted on the main thread when `isConnected` or `isConstrained` changes.
	public static let networkStatusDidChange = Notification.Name("NetworkStatusDidChange")
}

#if canImport(Network)

nonisolated public final class NetworkMonitor: Sendable {
	public static let shared = NetworkMonitor()

	private let monitor: NWPathMonitor
	private let queue = DispatchQueue(label: "RSWeb NetworkMonitor")

	private struct State: Sendable {
		var isConnected: Bool?
		var connectionType: NWInterface.InterfaceType?
		var isConstrained = false
	}

	private let state = Mutex(State())

	/// `true` until `NWPathMonitor` delivers its first path, so callers attempt
	/// network work rather than skip it on an answer we don't have yet.
	public var isConnected: Bool {
		state.withLock { $0.isConnected ?? true }
	}

	public var connectionType: NWInterface.InterfaceType? {
		state.withLock { $0.connectionType }
	}

	/// Is the connection constrained (Low Data Mode enabled, for instance)
	public var isConstrained: Bool {
		state.withLock { $0.isConstrained }
	}

	@MainActor private var monitorIsActive = false

	private init() {
		monitor = NWPathMonitor()

		monitor.pathUpdateHandler = { [weak self] path in
			self?.updateStatus(with: path)
		}
	}

	@MainActor public func start() {
		guard !monitorIsActive else {
			assertionFailure("start called when already active")
			return
		}
		monitorIsActive = true
		monitor.start(queue: queue)
	}

	deinit {
		monitor.cancel()
	}

	private func updateStatus(with path: NWPath) {
		let statusDidChange = state.withLock { state in
			let isConnected = path.status == .satisfied
			let statusDidChange = isConnected != (state.isConnected ?? true) || path.isConstrained != state.isConstrained
			state.isConnected = isConnected
			state.connectionType = path.availableInterfaces.first?.type
			state.isConstrained = path.isConstrained
			return statusDidChange
		}
		guard statusDidChange else {
			return
		}
		Task { @MainActor in
			NotificationCenter.default.post(name: .networkStatusDidChange, object: self)
		}
	}
}

#elseif os(Windows)

/// Windows backend: the network connectivity hint API (Windows 10 2004 and later),
/// which reports both reachability and cost — the counterpart of `NWPathMonitor`.
nonisolated public final class NetworkMonitor: Sendable {
	public static let shared = NetworkMonitor()

	private struct State: Sendable {
		var isConnected: Bool?
		var isConstrained = false
		var notificationHandle: UInt?
	}

	private let state = Mutex(State())

	/// `true` until Windows delivers its first hint, so callers attempt
	/// network work rather than skip it on an answer we don't have yet.
	public var isConnected: Bool {
		state.withLock { $0.isConnected ?? true }
	}

	/// Is the connection metered, roaming, or near or over its data limit — the
	/// Windows counterpart of Low Data Mode.
	public var isConstrained: Bool {
		state.withLock { $0.isConstrained }
	}

	@MainActor private var monitorIsActive = false

	private init() {
	}

	@MainActor public func start() {
		guard !monitorIsActive else {
			assertionFailure("start called when already active")
			return
		}
		monitorIsActive = true

		var handle: HANDLE?
		// The callback runs on a system thread pool thread, first right away (InitialNotification).
		let result = NotifyNetworkConnectivityHintChange({ _, hint in
			NetworkMonitor.shared.updateStatus(with: hint)
		}, nil, 1, &handle)
		guard result == 0, let handle else {
			return
		}
		state.withLock { $0.notificationHandle = UInt(bitPattern: handle) }
	}

	deinit {
		if let handle = state.withLock({ $0.notificationHandle }), let pointer = HANDLE(bitPattern: handle) {
			CancelMibChangeNotify2(pointer)
		}
	}

	private func updateStatus(with hint: NL_NETWORK_CONNECTIVITY_HINT) {
		let isConnected: Bool? = switch hint.ConnectivityLevel {
		case NetworkConnectivityLevelHintInternetAccess, NetworkConnectivityLevelHintConstrainedInternetAccess:
			true
		case NetworkConnectivityLevelHintNone, NetworkConnectivityLevelHintLocalAccess:
			false
		default:
			nil // Unknown or Hidden: no answer, so don't block network work.
		}
		let isMetered = hint.ConnectivityCost == NetworkConnectivityCostHintFixed || hint.ConnectivityCost == NetworkConnectivityCostHintVariable
		let isConstrained = isMetered || hint.ApproachingDataLimit != 0 || hint.OverDataLimit != 0 || hint.Roaming != 0

		let statusDidChange = state.withLock { state in
			let statusDidChange = (isConnected ?? true) != (state.isConnected ?? true) || isConstrained != state.isConstrained
			state.isConnected = isConnected
			state.isConstrained = isConstrained
			return statusDidChange
		}
		guard statusDidChange else {
			return
		}
		Task { @MainActor in
			NotificationCenter.default.post(name: .networkStatusDidChange, object: self)
		}
	}
}

#else

/// Platforms without a network monitor backend always report a usable connection.
nonisolated public final class NetworkMonitor: Sendable {
	public static let shared = NetworkMonitor()

	public var isConnected: Bool {
		true
	}

	public var isConstrained: Bool {
		false
	}

	private init() {
	}

	@MainActor public func start() {
	}
}

#endif
