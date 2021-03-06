//
//  KSCrashHandler.swift
//  SentrySwift
//
//  Created by Josh Holtz on 2/2/16.
//
//

import KSCrash
import Foundation

extension SentryClient {
	public func startCrashHandler() {
		crashHandler = KSCrashHandler(client: self)
	}
}

private typealias CrashDictionary = [String: AnyObject]

private let keyUser = "user"
private let keyEventTags = "event_tags"
private let keyEventExtra = "event_extra"
private let keyBreadcrumbsSerialized = "breadcrumbs_serialized"
private let keyReleaseVersion = "releaseVersion_serialized"


/// A class to report crashes to Sentry built upon KSCrash
internal class KSCrashHandler: CrashHandler {

	// MARK: - Attributes

	private var installation: KSCrashSentryInstallation
	
	private var lock = NSObject()
	private var isInstalled = false

	// MARK: - EventProperties

	internal var releaseVersion: String? {
		didSet { updateUserInfo() }
	}
	internal var tags: EventTags = [:] {
		didSet { updateUserInfo() }
	}
	internal var extra: EventExtra = [:] {
		didSet { updateUserInfo() }
	}
	internal var user: User? {
		didSet { updateUserInfo() }
	}

	required init(client: SentryClient) {
		installation = KSCrashSentryInstallation(client: client)
	}

	// MARK: - CrashHandler

	internal var breadcrumbsSerialized: BreadcrumbStore.SerializedType? {
		didSet { updateUserInfo() }
	}

	/*
	Starts the crash reporting and sends any previously saved crash reports
	- Parameter createdEvent: A closure that passes in a created event
	*/
	internal func startCrashReporting() {
		// Sychrnoizes this function
		objc_sync_enter(lock)
		defer { objc_sync_exit(lock) }

		// Return out if already installed
		if isInstalled { return }
		isInstalled = true
		
		// Install
		installation.install()

		// Maps KSCrash reports in `Events`
		installation.sendAllReportsWithCompletion() { (filteredReports, completed, error) -> Void in
			SentryLog.Debug.log("Sent \(filteredReports.count) report(s)")
		}
	}


	// MARK: - Private Helpers

	private func updateUserInfo() {
		var userInfo = CrashDictionary()
		userInfo[keyEventTags] = tags
		userInfo[keyEventExtra] = extra
		userInfo[keyReleaseVersion] = releaseVersion

		if let user = user?.serialized {
			userInfo[keyUser] = user
		}

		if let breadcrumbsSerialized = breadcrumbsSerialized {
			userInfo[keyBreadcrumbsSerialized] = breadcrumbsSerialized
		}

		KSCrash.sharedInstance().userInfo = userInfo
	}

}

private class KSCrashSentryInstallation: KSCrashInstallation {
	
	private let client: SentryClient
	
	init(client: SentryClient) {
		self.client = client
		super.init(requiredProperties: [])
	}
	
	override func sink() -> KSCrashReportFilter! {
		return KSCrashReportSinkSentry(client: client)
	}
	
}

private class KSCrashReportSinkSentry: NSObject, KSCrashReportFilter {
	
	private let client: SentryClient
	
	init(client: SentryClient) {
		self.client = client
		super.init()
	}
	
	@objc func filterReports(reports: [AnyObject]!, onCompletion: KSCrashReportFilterCompletion!) {
		
		// Mapping reports
		let events: [Event] = reports?
			.flatMap({$0 as? CrashDictionary})
			.map({mapReportToEvent($0)}) ?? []
		
		// Sends events recursively
		sendEvent(reports, events: events, success: true, onCompletion: onCompletion)
	}
	
	private func sendEvent(reports: [AnyObject]!, events allEvents: [Event], success: Bool, onCompletion: KSCrashReportFilterCompletion!) {
		var events = allEvents
		
		// Complete when no more
		guard let event = events.popLast() else {
			onCompletion(reports, success, nil)
			return
		}
		
		// Send event
		client.captureEvent(event, useClientProperties: true) { [weak self] eventSuccess in
			self?.sendEvent(reports, events: events, success: success && eventSuccess, onCompletion: onCompletion)
		}
	}
	
	private func mapReportToEvent(report: CrashDictionary) -> Event {
		SentryLog.Debug.log("Found report: \(report)")

		// Extract crash timestamp
		let timestamp: NSDate = {
			var date: NSDate?
			if let timestampStr = report["report"]?["timestamp"] as? String {
				let dateFormatter = NSDateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
				dateFormatter.locale = NSLocale(localeIdentifier: "en_US_POSIX")
				dateFormatter.timeZone = NSTimeZone(forSecondsFromGMT: 0)
				date = dateFormatter.dateFromString(timestampStr)
			}
			return date ?? NSDate()
		}()

		// Populate user info
		let userInfo = self.parseUserInfo(report["user"] as? CrashDictionary)

		// Generate Apple crash report
		let appleCrashReport: AppleCrashReport? = {
			guard let
				crash = report["crash"] as? [String: AnyObject],
				binaryImages = report["binary_images"] as? [[String: AnyObject]],
				system = report["system"] as? [String: AnyObject] else {
					return nil
				}
			return AppleCrashReport(crash: crash, binaryImages: binaryImages, system: system)
		}()

		/// Generate event to sent up to API
		/// Sends a blank message because server does stuff
		let event = Event.build("") {
			$0.level = .Fatal
			$0.timestamp = timestamp
			$0.tags = userInfo.tags ?? [:]
			$0.extra = userInfo.extra ?? [:]
			$0.user = userInfo.user
			$0.appleCrashReport = appleCrashReport
			$0.breadcrumbsSerialized = userInfo.breadcrumbsSerialized
			$0.releaseVersion = userInfo.releaseVersion
		}
		
		return event
	}
	
	private func parseUserInfo(userInfo: CrashDictionary?) -> (tags: EventTags?, extra: EventExtra?, user: User?, breadcrumbsSerialized: BreadcrumbStore.SerializedType?, releaseVersion:String?) {
		return (
			userInfo?[keyEventTags] as? EventTags,
			userInfo?[keyEventExtra] as? EventExtra,
			User(dictionary: userInfo?[keyUser] as? [String: AnyObject]),
			userInfo?[keyBreadcrumbsSerialized] as? BreadcrumbStore.SerializedType,
			userInfo?[keyReleaseVersion] as? String
		)
	}
	
}
