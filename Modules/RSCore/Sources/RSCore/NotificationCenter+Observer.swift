//
//  NotificationCenter+Observer.swift
//  RSCore
//
//  Replacement for addObserver(_:selector:name:object:) that needs no Objective-C
//  runtime, so the same code runs on Apple platforms and Windows.
//

import Foundation
import Synchronization

public extension NotificationCenter {

	/// Calls `handler` with `observer` for each matching notification, synchronously on the
	/// posting thread — as a selector-based observer is called. The observer is held weakly;
	/// once it is gone, the registration removes itself.
	nonisolated func addObserver<Observer: AnyObject & Sendable>(_ observer: Observer, name: Notification.Name?, object: Any? = nil, using handler: @escaping @Sendable (Observer, Notification) -> Void) {
		let registration = ObserverRegistration()
		let token = addObserver(forName: name, object: object, queue: nil) { [weak observer, weak self] notification in
			guard let observer else {
				if let self {
					registration.remove(from: self)
				}
				return
			}
			handler(observer, notification)
		}
		registration.set(token)
	}

	/// Like `addObserver(_:name:object:using:)` for a main actor observer. Notifications must be
	/// posted on the main thread — as with an `@objc` method of a main actor class, which
	/// Swift 6 checks at run time.
	nonisolated func addMainActorObserver<Observer: AnyObject & Sendable>(_ observer: Observer, name: Notification.Name?, object: Any? = nil, using handler: @escaping @MainActor (Observer, Notification) -> Void) {
		addObserver(observer, name: name, object: object) { observer, notification in
			// Notification isn't Sendable, but this runs synchronously on the posting (main) thread.
			nonisolated(unsafe) let notification = notification
			MainActor.assumeIsolated {
				handler(observer, notification)
			}
		}
	}
}

/// Holds the token from `addObserver(forName:object:queue:using:)` so the block can remove
/// its own registration.
private final class ObserverRegistration: Sendable {

	private let token = Mutex<NSObjectProtocolBox?>(nil)

	func set(_ token: any NSObjectProtocol) {
		self.token.withLock { $0 = NSObjectProtocolBox(token) }
	}

	func remove(from notificationCenter: NotificationCenter) {
		guard let box = token.withLock({ $0.take() }) else {
			return
		}
		notificationCenter.removeObserver(box.token)
	}
}

/// The observer token is an opaque object that NotificationCenter uses only for removal.
private struct NSObjectProtocolBox: @unchecked Sendable {
	let token: any NSObjectProtocol

	init(_ token: any NSObjectProtocol) {
		self.token = token
	}
}
