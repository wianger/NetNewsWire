//
//  CoalescingQueue.swift
//  RSCore
//
//  Created by Brent Simmons on 2/17/18.
//  Copyright © 2018 Ranchero Software, LLC. All rights reserved.
//

import Foundation

// Use when you want to coalesce calls for something like updating visible table cells.
// Calls are uniqued. If you add a call with the same target and id as a previous call, you’ll just get one call.
// Targets are weakly-held. If a target goes to nil, the call is not performed.
// The perform date is pushed off every time a call is added.
// Calls are FIFO.

// Calls are identified by target and id (on Objective-C platforms, the selector name).

struct QueueCall {
	weak var target: AnyObject?
	let id: String
	let action: @MainActor (AnyObject) -> Void

	@MainActor func perform() {
		if let target {
			action(target)
		}
	}

	func isSameCall(as other: QueueCall) -> Bool {
		target === other.target && id == other.id
	}
}

@MainActor public final class CoalescingQueue: NSObject {

	public static let standard = CoalescingQueue(name: "Standard", interval: 0.05, maxInterval: 0.1)
	public let name: String
	public var isPaused = false
	private let interval: TimeInterval
	private let maxInterval: TimeInterval
	private var lastCallTime = Date.distantFuture
	// A Task rather than a Timer: the main RunLoop does not run when the core is hosted
	// by another UI framework (Windows), but the main actor does.
	private var timerTask: Task<Void, Never>?
	private var calls = [QueueCall]()

	nonisolated public init(name: String, interval: TimeInterval = 0.05, maxInterval: TimeInterval = 2.0) {
		self.name = name
		self.interval = interval
		self.maxInterval = maxInterval
	}

	/// Adds a call identified by `target` and `id`. Adding the same call again before
	/// the queue fires results in a single call.
	public func add<Target: AnyObject>(_ target: Target, id: String, _ action: @escaping @MainActor (Target) -> Void) {
		let queueCall = QueueCall(target: target, id: id) { object in
			if let target = object as? Target {
				action(target)
			}
		}
		add(queueCall)
		if Date().timeIntervalSince1970 - lastCallTime.timeIntervalSince1970 > maxInterval {
			timerDidFire()
		}
	}

	#if canImport(ObjectiveC)
	public func add(_ target: AnyObject, _ selector: Selector) {
		add(target, id: NSStringFromSelector(selector)) { target in
			_ = target.perform(selector)
		}
	}
	#endif

	public func performCallsImmediately() {
		guard !isPaused else { return }
		let callsToMake = calls // Make a copy in case calls are added to the queue while performing calls.
		resetCalls()
		for call in callsToMake {
			call.perform()
		}
	}

	func timerDidFire() {
		lastCallTime = Date()
		performCallsImmediately()
	}
}

private extension CoalescingQueue {

	func add(_ call: QueueCall) {
		restartTimer()

		if !calls.contains(where: { $0.isSameCall(as: call) }) {
			calls.append(call)
		}
	}

	func resetCalls() {
		calls = [QueueCall]()
	}

	func restartTimer() {
		invalidateTimer()
		let interval = interval
		timerTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(interval))
			guard !Task.isCancelled else {
				return
			}
			self?.timerDidFire()
		}
	}

	func invalidateTimer() {
		timerTask?.cancel()
		timerTask = nil
	}
}
