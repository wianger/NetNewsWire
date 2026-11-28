//
//  CoreService+Timers.swift
//  CoreService
//
//  The Mac's two refresh timers (Shared/Timer), which use Objective-C timer selectors and so
//  can't be shared: AccountRefreshTimer refreshes every account at the user's interval, the first
//  time at launch; ArticleStatusSyncTimer sends and fetches read and starred statuses every two
//  minutes, every 30 when there was nothing to do, and returns to two minutes as soon as a
//  status change is queued.
//
//  Both check the wall clock rather than counting down a sleep, so a PC that slept past a due
//  time refreshes soon after it wakes — as the Mac's timers fire an overdue refresh on wake.
//

import Foundation
import RSCore
import Account

extension CoreService {

	/// Starts the timers, or changes the interval. `refreshNow` refreshes at once, as the Mac does at launch.
	func scheduleRefresh(_ params: RefreshScheduleParams) {
		refreshScheduler.interval = params.intervalSeconds.flatMap { $0 > 0 ? TimeInterval($0) : nil }
		if params.refreshNow == true {
			refreshScheduler.fireNow()
		}
		statusSyncScheduler.start()
	}
}

struct RefreshScheduleParams: Decodable {
	/// Nil or 0: refresh only when asked, as the Mac's Manually setting.
	let intervalSeconds: Int?
	let refreshNow: Bool?
}

/// Runs an action at an interval measured from the last time it ran, checking the clock at least once a minute.
@MainActor final class RefreshScheduler {

	/// Nil stops the timer. Changing it reschedules from the last run.
	var interval: TimeInterval? {
		didSet {
			restart()
		}
	}

	private(set) var lastRun: Date
	private let action: @MainActor () -> Void
	private let checkInterval: TimeInterval
	private var task: Task<Void, Never>?

	init(checkInterval: TimeInterval = 60, action: @escaping @MainActor () -> Void) {
		self.lastRun = Date()
		self.checkInterval = checkInterval
		self.action = action
	}

	func fireNow() {
		lastRun = Date()
		action()
		restart()
	}

	func stop() {
		task?.cancel()
		task = nil
	}

	private func restart() {
		stop()
		guard let interval else {
			return
		}
		task = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else {
					return
				}
				let due = self.lastRun.addingTimeInterval(interval)
				let wait = due.timeIntervalSinceNow
				if wait > 0 {
					try? await Task.sleep(for: .seconds(min(wait, self.checkInterval)))
					continue
				}
				self.lastRun = Date()
				self.action()
			}
		}
	}
}

/// The Mac's ArticleStatusSyncTimer: every two minutes, backing off to 30 when a sync had nothing to do.
@MainActor final class StatusSyncScheduler {

	static let normalInterval: TimeInterval = 120
	static let idleBackoffInterval: TimeInterval = 1800

	private(set) var isIdle = false
	private var scheduler: RefreshScheduler?
	private let sync: @MainActor () async -> Bool

	/// - Parameter sync: Sends and fetches statuses; true if there was anything to do.
	init(sync: @escaping @MainActor () async -> Bool) {
		self.sync = sync
	}

	func start(checkInterval: TimeInterval = 60) {
		guard scheduler == nil else {
			return
		}
		let scheduler = RefreshScheduler(checkInterval: checkInterval) { [weak self] in
			self?.runSync()
		}
		self.scheduler = scheduler
		scheduler.interval = Self.normalInterval
		NotificationCenter.default.addMainActorObserver(self, name: .AccountDidQueueArticleStatuses) { syncScheduler, _ in
			syncScheduler.statusesWereQueued()
		}
	}

	/// A user changed a status: leave the idle backoff, so it's sent on the normal schedule.
	func statusesWereQueued() {
		guard isIdle else {
			return
		}
		isIdle = false
		scheduler?.interval = Self.normalInterval
	}

	func stop() {
		scheduler?.stop()
	}

	private func runSync() {
		Task { @MainActor in
			await syncAndReschedule()
		}
	}

	private func syncAndReschedule() async {
		let didWork = await sync()
		isIdle = !didWork
		let interval = didWork ? Self.normalInterval : Self.idleBackoffInterval
		if scheduler?.interval != interval {
			scheduler?.interval = interval
		}
	}

	/// A sync now, waiting for it, for tests.
	func syncNowForTesting() async {
		await syncAndReschedule()
	}
}
