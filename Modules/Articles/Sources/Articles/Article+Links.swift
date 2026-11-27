//
//  Article+Links.swift
//  Articles
//
//  Links and dates as the apps show them. Moved here from the app’s Shared/Extensions
//  so every app — Mac, iOS, Windows — and the article renderer use the same rules.
//

import Foundation
import RSCore

public extension Article {

	var url: URL? {
		URL.encodeSpacesIfNeeded(rawLink)
	}

	var externalURL: URL? {
		URL.encodeSpacesIfNeeded(rawExternalLink)
	}

	var preferredURL: URL? {
		url ?? externalURL
	}

	var imageURL: URL? {
		URL.encodeSpacesIfNeeded(rawImageLink)
	}

	var thumbnailURL: URL? {
		URL.encodeSpacesIfNeeded(rawThumbnailLink)
	}

	/// The link from `url`, which repairs spaces, or the raw link if no URL can be made from it.
	var link: String? {
		url?.absoluteString ?? rawLink
	}

	var externalLink: String? {
		externalURL?.absoluteString ?? rawExternalLink
	}

	var imageLink: String? {
		imageURL?.absoluteString ?? rawImageLink
	}

	var thumbnailLink: String? {
		thumbnailURL?.absoluteString ?? rawThumbnailLink
	}

	/// The link, else the external link. Nil if both are missing or empty.
	var preferredLink: String? {
		if let link, !link.isEmpty {
			return link
		}
		if let externalLink, !externalLink.isEmpty {
			return externalLink
		}
		return nil
	}

	var body: String? {
		contentHTML ?? contentText ?? summary
	}

	/// The date the timeline shows and sorts by.
	var logicalDatePublished: Date {
		datePublished ?? dateModified ?? status.dateArrived
	}
}
