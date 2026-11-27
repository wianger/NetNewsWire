//
//  ArticleSortParameters.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/18/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Articles

// ArticleSortKey and ArticleSortParameters are in the Articles module, shared with Windows.

extension ArticleSortKey {

	var localizedName: String {
		switch self {
		case .date:
			NSLocalizedString("Date", comment: "Timeline column header")
		case .feed:
			NSLocalizedString("Feed", comment: "Timeline column header")
		case .title:
			NSLocalizedString("Title", comment: "Timeline column header")
		case .unread:
			NSLocalizedString("timeline.column.unread", value: "Unread", comment: "Timeline column and sort field name")
		case .starred:
			NSLocalizedString("timeline.column.starred", value: "Starred", comment: "Timeline column and sort field name")
		}
	}

	/// Menu title for a direction, worded for the field: dates by age, text alphabetically, flags ascending or descending.
	func localizedDirectionTitle(ascending: Bool) -> String {
		let ascendingTitle: String
		let descendingTitle: String
		switch self {
		case .date:
			ascendingTitle = NSLocalizedString("Oldest Article on Top", comment: "Sort direction")
			descendingTitle = NSLocalizedString("Newest Article on Top", comment: "Sort direction")
		case .feed, .title:
			ascendingTitle = NSLocalizedString("A to Z", comment: "Sort direction")
			descendingTitle = NSLocalizedString("Z to A", comment: "Sort direction")
		case .unread, .starred:
			ascendingTitle = NSLocalizedString("Ascending", comment: "Sort direction")
			descendingTitle = NSLocalizedString("Descending", comment: "Sort direction")
		}
		return ascending ? ascendingTitle : descendingTitle
	}
}
