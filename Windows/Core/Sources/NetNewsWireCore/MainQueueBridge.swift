//
//  MainQueueBridge.swift
//  NetNewsWireCore
//
//  Lets the host app's UI thread drain the libdispatch main queue,
//  so that `@MainActor` code in the core runs on the WinUI UI thread —
//  the same semantics as on macOS and iOS.
//
//  On Windows, Swift's main executor enqueues onto the libdispatch main queue.
//  Normally CFRunLoop drains it, but a WinUI app runs its own message loop,
//  so nothing would ever run. The host waits on the main queue's handle and
//  calls `nnw_drain_main_queue` on its UI thread when it is signaled.
//
//  This can be replaced by a DispatcherQueue-based custom main executor once
//  Swift ships "Custom Main and Global Executors".
//

import Dispatch
#if os(Windows)
import WinSDK
#endif

@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchGetMainQueueHandle() -> UnsafeMutableRawPointer?

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

/// Returns the waitable handle (a Win32 event) that libdispatch signals
/// when work is enqueued on the main queue.
@c(nnw_main_queue_handle)
public func mainQueueHandle() -> UnsafeMutableRawPointer? {
	dispatchGetMainQueueHandle()
}

/// Drains the main queue. Must be called on the thread that loaded the core
/// (the host's UI thread).
@c(nnw_drain_main_queue)
public func drainMainQueue() {
	#if os(Windows)
	// Reset before draining so that work enqueued during the drain
	// signals the event again instead of being lost.
	if let handle = dispatchGetMainQueueHandle() {
		ResetEvent(handle)
	}
	#endif
	dispatchMainQueueCallback(nil)
}
