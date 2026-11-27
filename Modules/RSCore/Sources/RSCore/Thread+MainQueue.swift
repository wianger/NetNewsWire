//
//  Thread+MainQueue.swift
//  RSCore
//
//  On Apple platforms the main dispatch queue — the main actor's executor — always runs on
//  the main thread. Elsewhere it may not: after dispatch_main(), which an async main calls,
//  a worker thread drains it. Code checking “am I where main actor work runs” should ask this.
//

import Foundation
import Dispatch

public extension Thread {

	/// True when running where the main dispatch queue runs: the main thread on Apple platforms;
	/// elsewhere, the main thread or whichever thread is draining the main queue.
	nonisolated static var isMainQueue: Bool {
#if canImport(Darwin)
		isMainThread
#else
		isMainThread || DispatchQueue.getSpecific(key: mainQueueKey.key) == true
#endif
	}
}

#if !canImport(Darwin)
/// Identifies the main dispatch queue, set on it the first time it is used.
private let mainQueueKey: MainQueueKey = {
	let mainQueueKey = MainQueueKey()
	DispatchQueue.main.setSpecific(key: mainQueueKey.key, value: true)
	return mainQueueKey
}()

private final class MainQueueKey: Sendable {
	let key = DispatchSpecificKey<Bool>()
}
#endif
