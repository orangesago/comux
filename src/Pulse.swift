import Foundation
import SwiftUI

enum RefreshFreshnessPolicy {
    static let menuMaximumAge: TimeInterval = 30

    static func shouldRefresh(
        lastCompletedAt: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        guard let lastCompletedAt else {
            return true
        }

        return now.timeIntervalSince(lastCompletedAt) >= maximumAge
    }
}

enum RefreshRequestKind {
    case passive
    case stateChange
}

enum RefreshCoalescingPolicy {
    static func shouldQueueFollowUp(
        isSyncing: Bool,
        requestKind: RefreshRequestKind
    ) -> Bool {
        isSyncing && requestKind == .stateChange
    }
}

enum RefreshPublicationPolicy {
    static func shouldPublish(
        snapshotCount: Int,
        systemStateWasRefreshed: Bool
    ) -> Bool {
        systemStateWasRefreshed || snapshotCount > 0
    }
}

enum RefreshConcurrencyPolicy {
    static let maximumConcurrentFetches = 3
}

struct RefreshRetryBackoff {
    private(set) var nextDelay: TimeInterval = 1

    mutating func takeDelay() -> TimeInterval {
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, 120)
        return delay
    }

    mutating func reset() {
        nextDelay = 1
    }
}

@MainActor
final class PulseCoordinator: ObservableObject {
    @Published var cache = CachePayload(
        meta: CacheMeta(
            source: "native-swift-cache"
        ),
        accounts: []
    )
    @Published private(set) var removableAccountIDs = Set<String>()

    private let cacheStore = CacheStore()
    private let accountConfigStore = AccountConfigStore()
    private let durableStore = DurableStoreCoordinator.shared
    private let snapshotMerger = AccountSnapshotMerger()
    private let authenticatedSession = CodexAuthenticatedSession.shared
    private var hasStarted = false
    private var isSyncing = false
    nonisolated(unsafe) private var syncTimer: Timer?
    nonisolated(unsafe) private var authMonitorSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var authMonitorFileDescriptor: CInt = -1
    private var lastObservedAuthSignature: AuthFileSignature?
    private var lastSyncCompletedAt: Date?
    private var authRetryTask: Task<Void, Never>?
    private var authRetryBackoff = RefreshRetryBackoff()
    private var needsSyncAfterCurrent = false
    private var removalSuppressions = AccountRemovalSuppressions()

    var accountCount: Int {
        self.cache.accounts.count
    }

    func start() {
        guard !self.hasStarted else {
            return
        }

        self.hasStarted = true
        self.cache = self.cacheStore.load()
        self.removableAccountIDs = self.buildRemovableAccountIDs(
            for: self.cache.accounts
        )
        self.lastObservedAuthSignature = self.currentAuthFileSignature()
        self.startAuthFileMonitor()

        // Initial sync
        Task {
            await self.syncNow()
        }

        // Periodic sync every 2 minutes
        self.syncTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
    }

    deinit {
        self.syncTimer?.invalidate()
        self.authRetryTask?.cancel()
        self.authMonitorSource?.cancel()
        if self.authMonitorFileDescriptor >= 0 {
            close(self.authMonitorFileDescriptor)
            self.authMonitorFileDescriptor = -1
        }
    }

    func syncNow(requestKind: RefreshRequestKind = .passive) async {
        if self.isSyncing {
            if RefreshCoalescingPolicy.shouldQueueFollowUp(
                isSyncing: true,
                requestKind: requestKind
            ) {
                self.needsSyncAfterCurrent = true
            }
            return
        }

        repeat {
            self.needsSyncAfterCurrent = false
            self.isSyncing = true
            await self.performSyncNow()
            self.lastSyncCompletedAt = Date()
            self.isSyncing = false
        } while self.needsSyncAfterCurrent
    }

    func syncIfMenuCacheIsStale(now: Date = Date()) async {
        guard RefreshFreshnessPolicy.shouldRefresh(
            lastCompletedAt: self.lastSyncCompletedAt,
            now: now,
            maximumAge: RefreshFreshnessPolicy.menuMaximumAge
        ) else {
            return
        }

        await self.syncNow()
    }

    private func performSyncNow() async {
        let config = self.accountConfigStore.load()
        var incomingSnapshots: [AccountSnapshot] = []
        var didRefreshSystemState = false

        do {
            let systemRefresh = try await self.buildSystemSnapshotRefresh()
            self.resetAuthRefreshRetry()
            incomingSnapshots.append(contentsOf: systemRefresh.snapshots)
            didRefreshSystemState = true
        } catch {
            if SystemRefreshErrorPolicy.shouldTreatAsRefreshedSystemState(error) {
                self.resetAuthRefreshRetry()
                didRefreshSystemState = true
                self.removalSuppressions.clearSystemAuthSuppressions()
            } else {
                self.lastObservedAuthSignature = self.currentAuthFileSignature()
                self.scheduleAuthRefreshRetryIfNeeded()
            }
        }

        let configuredSnapshots = try? await BoundedConcurrency.map(
            config.accounts,
            limit: RefreshConcurrencyPolicy.maximumConcurrentFetches
        ) { [self] account in
            try? await self.buildCookieSnapshot(for: account)
        }
        incomingSnapshots.append(contentsOf: configuredSnapshots?.compactMap { $0 } ?? [])

        if RefreshPublicationPolicy.shouldPublish(
            snapshotCount: incomingSnapshots.count,
            systemStateWasRefreshed: didRefreshSystemState
        ) {
            self.publishMergedSnapshots(
                incomingSnapshots,
                config: config,
                systemStateWasRefreshed: didRefreshSystemState
            )
        }

        self.lastObservedAuthSignature = self.currentAuthFileSignature()
    }

    func isRemovable(_ account: AccountSnapshot) -> Bool {
        self.removableAccountIDs.contains(account.accountId)
    }

    func removeAccount(_ account: AccountSnapshot) throws {
        let existingConfig = self.accountConfigStore.load()
        let removal = AccountRemovalResolver.remove(
            account,
            from: self.cache,
            config: existingConfig
        )

        guard removal.cache.accounts.count != self.cache.accounts.count
            || removal.config.accounts.count != existingConfig.accounts.count
        else {
            return
        }

        try self.durableStore.saveCacheAndConfig(
            cache: removal.cache,
            config: removal.config,
            event: "account.remove"
        )

        self.removalSuppressions.suppressRemoval(of: account)
        self.cache = removal.cache
        self.removableAccountIDs = AccountRemovalResolver.removableAccountIDs(
            for: removal.cache.accounts
        )
    }

    private func buildSystemSnapshotRefresh() async throws -> SystemSnapshotRefresh {
        guard let identity = try self.loadSystemIdentity() else {
            self.removalSuppressions.clearSystemAuthSuppressions()
            return SystemSnapshotRefresh(snapshots: [])
        }

        let currentUsage = try await self.fetchUsagePayload(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: identity.accountId
        )
        let currentWorkspaceAccountID = self.normalizeWorkspaceAccountID(
            (currentUsage["account_id"] as? String) ?? identity.accountId
        )
        let apiUsageWindows = UsageWindowPayloadParser.parse(
            rateLimit: currentUsage["rate_limit"] as? [String: Any]
        )
        let currentWorkspaceAccountHeader = (currentUsage["account_id"] as? String)
            ?? identity.accountId
        async let preferredCurrentRateLimits = self.readCurrentRateLimits(
            apiUsageWindows: apiUsageWindows,
            accessToken: identity.accessToken,
            accountHeader: currentWorkspaceAccountHeader
        )
        let workspaceItems = try await self.fetchWorkspaceItems(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            accountHeader: identity.accountId ?? currentWorkspaceAccountID
        )
        let currentRateLimits = await preferredCurrentRateLimits

        var indexedSnapshots: [(Int, AccountSnapshot)] = []
        var remoteWorkspaceItems: [(Int, WorkspaceItem)] = []

        for (index, workspaceItem) in workspaceItems.enumerated() {
            let workspaceAccountID = AccountIdentity.trimmedWorkspaceID(workspaceItem.id)
            guard self.normalizeWorkspaceAccountID(workspaceAccountID) == currentWorkspaceAccountID else {
                remoteWorkspaceItems.append((index, workspaceItem))
                continue
            }

            let responseWorkspaceAccountID = self.normalizeWorkspaceAccountID(
                currentUsage["account_id"] as? String
            )

            if let workspaceAccountID,
               responseWorkspaceAccountID != nil,
               responseWorkspaceAccountID != self.normalizeWorkspaceAccountID(workspaceAccountID) {
                continue
            }

            let snapshot = try self.normalizeUsage(
                currentUsage,
                accountID: workspaceItem.id,
                label: identity.name ?? currentUsage["email"] as? String ?? identity.email ?? "Current system account",
                email: currentUsage["email"] as? String ?? identity.email ?? "Unknown account",
                workspaceID: workspaceItem.id,
                workspaceLabel: self.resolveWorkspaceName(
                    currentUsage,
                    workspaceItem: workspaceItem,
                    identity: identity
                ),
                plan: self.displayPlan(currentUsage["plan_type"] as? String ?? identity.planType),
                source: "live system auth",
                systemAuthProfileID: normalizedSystemAuthProfileID(identity.subject ?? identity.email),
                isCurrentSystemAccount: true,
                resetCredits: currentRateLimits.resetCredits,
                preferredUsageWindows: currentRateLimits.usageWindows
            )
            indexedSnapshots.append((index, snapshot))
        }

        let remoteSnapshots = try await BoundedConcurrency.mapSuccessful(
            remoteWorkspaceItems,
            limit: RefreshConcurrencyPolicy.maximumConcurrentFetches
        ) { [self] indexedWorkspace in
            let (index, workspaceItem) = indexedWorkspace
            return (
                index,
                try await self.buildRemoteWorkspaceSnapshot(
                    workspaceItem,
                    identity: identity
                )
            )
        }
        indexedSnapshots.append(contentsOf: remoteSnapshots.compactMap { index, snapshot in
            snapshot.map { (index, $0) }
        })

        var snapshots = indexedSnapshots
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        if snapshots.allSatisfy({ $0.isCurrentSystemAccount != true }) {
            snapshots.append(
                try self.buildCurrentSystemSnapshot(
                    currentUsage,
                    identity: identity,
                    resetCredits: currentRateLimits.resetCredits,
                    preferredUsageWindows: currentRateLimits.usageWindows
                )
            )
        }

        return SystemSnapshotRefresh(snapshots: snapshots)
    }

    private func buildRemoteWorkspaceSnapshot(
        _ workspaceItem: WorkspaceItem,
        identity: SystemAuthIdentity
    ) async throws -> AccountSnapshot? {
        let workspaceAccountID = AccountIdentity.trimmedWorkspaceID(workspaceItem.id)
        let rawUsage = try await self.fetchUsagePayload(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            usageEndpoint: "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: workspaceAccountID
        )
        let responseWorkspaceAccountID = self.normalizeWorkspaceAccountID(
            rawUsage["account_id"] as? String
        )

        if let workspaceAccountID,
           responseWorkspaceAccountID != nil,
           responseWorkspaceAccountID != self.normalizeWorkspaceAccountID(workspaceAccountID) {
            return nil
        }

        let resetCredits = try? await self.fetchRateLimitResetCredits(
            accessToken: identity.accessToken,
            cookieHeader: nil,
            usageEndpoint: nil,
            accountHeader: workspaceAccountID
        )

        return try self.normalizeUsage(
            rawUsage,
            accountID: workspaceItem.id,
            label: identity.name ?? rawUsage["email"] as? String ?? identity.email ?? "Current system account",
            email: rawUsage["email"] as? String ?? identity.email ?? "Unknown account",
            workspaceID: workspaceItem.id,
            workspaceLabel: self.resolveWorkspaceName(
                rawUsage,
                workspaceItem: workspaceItem,
                identity: identity
            ),
            plan: self.displayPlan(rawUsage["plan_type"] as? String ?? identity.planType),
            source: "live system auth",
            systemAuthProfileID: normalizedSystemAuthProfileID(identity.subject ?? identity.email),
            isCurrentSystemAccount: false,
            resetCredits: resetCredits
        )
    }

    private func readCurrentRateLimits(
        apiUsageWindows: [UsageWindow],
        accessToken: String,
        accountHeader: String?
    ) async -> CodexRateLimitsSnapshot {
        let apiResetCredits = try? await self.fetchRateLimitResetCredits(
            accessToken: accessToken,
            cookieHeader: nil,
            usageEndpoint: nil,
            accountHeader: accountHeader
        )
        let appServer = CodexRateLimitsSourceResolver.needsAppServer(
            apiUsageWindows: apiUsageWindows
        )
            ? await CodexAppServerRateLimitsReader.read()
            : nil

        return CodexRateLimitsSourceResolver.resolve(
            apiUsageWindows: apiUsageWindows,
            apiResetCredits: apiResetCredits,
            appServer: appServer
        )
    }

    private func buildCurrentSystemSnapshot(
        _ currentUsage: [String: Any],
        identity: SystemAuthIdentity,
        resetCredits: CodexResetCredits?,
        preferredUsageWindows: [UsageWindow]?
    ) throws -> AccountSnapshot {
        let plan = self.displayPlan(currentUsage["plan_type"] as? String ?? identity.planType)
        let workspaceLabel = self.resolveWorkspaceLabel(
            payload: currentUsage,
            fallback: ""
        )
        let workspaceID = AccountIdentity.preferredStorageWorkspaceID(
            workspaceId: currentUsage["account_id"] as? String,
            fallbackAccountId: identity.accountId
        )

        return try self.normalizeUsage(
            currentUsage,
            accountID: workspaceID ?? identity.subject ?? UUID().uuidString,
            label: identity.name ?? currentUsage["email"] as? String ?? identity.email ?? "Current system account",
            email: currentUsage["email"] as? String ?? identity.email ?? "Unknown account",
            workspaceID: workspaceID,
            workspaceLabel: workspaceLabel,
            plan: plan,
            source: "live system auth",
            systemAuthProfileID: normalizedSystemAuthProfileID(identity.subject ?? identity.email),
            isCurrentSystemAccount: true,
            resetCredits: resetCredits,
            preferredUsageWindows: preferredUsageWindows
        )
    }

    private func buildCookieSnapshot(for account: AccountConfig) async throws -> AccountSnapshot {
        let accessToken = try await self.fetchAccessToken(for: account)
        let rawUsage = try await self.fetchUsagePayload(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            usageEndpoint: account.usageEndpoint ?? "https://chatgpt.com/backend-api/wham/usage",
            accountHeader: account.accountHeader
        )
        let workspaceAccountID = account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? account.accountHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
            : (rawUsage["account_id"] as? String)
        let workspaceLabel = (try? await self.fetchWorkspaceLabel(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            workspaceAccountID: workspaceAccountID
        )) ?? account.workspaceLabel
        let resetCredits = try? await self.fetchRateLimitResetCredits(
            accessToken: accessToken,
            cookieHeader: account.chatGPTCookie,
            usageEndpoint: account.usageEndpoint,
            accountHeader: workspaceAccountID
        )

        return try self.normalizeUsage(
            rawUsage,
            accountID: account.id,
            label: account.label,
            email: account.email,
            workspaceID: workspaceAccountID,
            workspaceLabel: workspaceLabel,
            plan: self.displayPlan(rawUsage["plan_type"] as? String) == "Codex"
                ? account.plan
                : self.displayPlan(rawUsage["plan_type"] as? String),
            source: account.source ?? "native cookie sync",
            systemAuthProfileID: nil,
            isCurrentSystemAccount: false,
            resetCredits: resetCredits
        )
    }

    private func loadSystemIdentity() throws -> SystemAuthIdentity? {
        guard FileManager.default.fileExists(atPath: ComuxPaths.codexAuth.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: ComuxPaths.codexAuth)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = payload["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else {
            throw PulseError.invalidAuthFile
        }

        let idToken = tokens["id_token"] as? String
        let idTokenClaims = idToken.flatMap(self.decodeJWTClaims)
        let planClaims = idTokenClaims?["https://api.openai.com/auth"] as? [String: Any]

        return SystemAuthIdentity(
            accessToken: accessToken,
            accountId: tokens["account_id"] as? String,
            email: idTokenClaims?["email"] as? String,
            name: idTokenClaims?["name"] as? String,
            planType: planClaims?["chatgpt_plan_type"] as? String,
            organizationTitles: self.resolveOrganizationTitles(from: planClaims),
            subject: idTokenClaims?["sub"] as? String
        )
    }

    private func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let components = token.split(separator: ".")
        guard components.count > 1 else {
            return nil
        }

        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4

        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private func fetchAccessToken(for account: AccountConfig) async throws -> String {
        let sessionURL = URL(string: account.sessionEndpoint ?? "https://chatgpt.com/api/auth/session")!
        var request = URLRequest(url: sessionURL)
        request.setValue(account.chatGPTCookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")

        let (data, _) = try await self.authenticatedSession.data(for: request)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let accessToken = payload?["accessToken"] as? String

        guard let accessToken, !accessToken.isEmpty else {
            throw PulseError.invalidSessionToken
        }

        return accessToken
    }

    private func fetchUsagePayload(
        accessToken: String,
        cookieHeader: String?,
        usageEndpoint: String,
        accountHeader: String?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: usageEndpoint)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let accountHeader, !accountHeader.isEmpty {
            request.setValue(accountHeader, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await self.authenticatedSession.data(for: request)
        return try UsagePayloadParser.parse(
            data: data,
            response: response
        )
    }

    private func fetchRateLimitResetCredits(
        accessToken: String,
        cookieHeader: String?,
        usageEndpoint: String?,
        accountHeader: String?
    ) async throws -> CodexResetCredits {
        var request = URLRequest(
            url: URL(string: self.rateLimitResetCreditsEndpoint(from: usageEndpoint))!,
            timeoutInterval: 4
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Comux", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        if let accountHeader, !accountHeader.isEmpty {
            request.setValue(accountHeader, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await self.authenticatedSession.data(for: request)
        return try ResetCreditsPayloadParser.parse(
            data: data,
            response: response
        )
    }

    private func rateLimitResetCreditsEndpoint(from usageEndpoint: String?) -> String {
        let fallback = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        guard let usageEndpoint,
              var components = URLComponents(string: usageEndpoint)
        else {
            return fallback
        }

        if components.path.hasSuffix("/wham/usage") {
            components.path = components.path.replacingOccurrences(
                of: "/wham/usage",
                with: "/wham/rate-limit-reset-credits"
            )
            return components.url?.absoluteString ?? fallback
        }

        return fallback
    }

    private func fetchWorkspaceItems(
        accessToken: String,
        cookieHeader: String?,
        accountHeader: String?
    ) async throws -> [WorkspaceItem] {
        let request = WorkspaceLabelResolver.workspaceListRequest(
            accessToken: accessToken,
            cookieHeader: cookieHeader,
            accountHeader: accountHeader
        )
        let (data, response) = try await self.authenticatedSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseError.workspaceListUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PulseError.workspaceListUnavailable
        }

        let payload = try JSONDecoder().decode(WorkspaceIdentity.self, from: data)
        return payload.items
    }

    private func fetchWorkspaceLabel(
        accessToken: String,
        cookieHeader: String?,
        workspaceAccountID: String?
    ) async throws -> String? {
        let workspaceItems = try await self.fetchWorkspaceItems(
            accessToken: accessToken,
            cookieHeader: cookieHeader,
            accountHeader: workspaceAccountID
        )
        return WorkspaceLabelResolver.resolve(
            workspaceItems: workspaceItems,
            workspaceAccountID: workspaceAccountID,
            normalizeWorkspaceAccountID: self.normalizeWorkspaceAccountID
        )
    }

    private func normalizeUsage(
        _ payload: [String: Any],
        accountID: String,
        label: String,
        email: String,
        workspaceID: String?,
        workspaceLabel: String,
        plan: String,
        source: String,
        systemAuthProfileID: String?,
        isCurrentSystemAccount: Bool,
        resetCredits: CodexResetCredits?,
        preferredUsageWindows: [UsageWindow]? = nil
    ) throws -> AccountSnapshot {
        let parsedUsageWindows = UsageWindowPayloadParser.parse(
            rateLimit: payload["rate_limit"] as? [String: Any]
        )
        let usageWindows: [UsageWindow]
        if let preferredUsageWindows, !preferredUsageWindows.isEmpty {
            usageWindows = preferredUsageWindows
        } else {
            usageWindows = parsedUsageWindows
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let resolvedWorkspaceLabel = self.resolveWorkspaceLabel(
            payload: payload,
            fallback: workspaceLabel
        )
        let displayWorkspaceLabel = normalizedWorkspaceLabel(
            resolvedWorkspaceLabel,
            plan: plan
        )
        let resolvedPlan = normalizedPlanLabel(
            plan,
            workspaceLabel: displayWorkspaceLabel
        )
        let snapshotKey = AccountIdentity.storageKey(
            email: email,
            workspaceId: workspaceID,
            workspaceLabel: resolvedWorkspaceLabel
        )

        return AccountSnapshot(
            accountId: snapshotKey,
            label: label,
            email: email,
            workspaceId: workspaceID,
            workspaceLabel: resolvedWorkspaceLabel,
            plan: resolvedPlan,
            source: source,
            systemAuthProfileId: systemAuthProfileID,
            isCurrentSystemAccount: isCurrentSystemAccount,
            lastSyncedAt: now,
            usageWindows: usageWindows,
            resetCredits: resetCredits
        )
    }

    private func resolveWorkspaceLabel(
        payload: [String: Any],
        fallback: String
    ) -> String {
        let directCandidates = [
            "workspace_name",
            "workspaceName",
            "team_workspace_name",
            "teamWorkspaceName",
            "current_workspace_name",
            "currentWorkspaceName",
            "organization_name",
            "organizationName",
            "account_organization",
            "accountOrganization"
        ]

        for key in directCandidates {
            if let value = payload[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        let nestedCandidates = [
            "workspace",
            "current_workspace",
            "team",
            "organization",
            "account",
            "identity",
            "subscription"
        ]

        for key in nestedCandidates {
            guard let nested = payload[key] as? [String: Any] else {
                continue
            }

            for nestedKey in [
                "name",
                "title",
                "workspace_name",
                "display_name",
                "organization_name",
                "account_organization"
            ] {
                if let value = nested[nestedKey] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }

        return fallback
    }

    private func resolveOrganizationTitles(from authClaims: [String: Any]?) -> [String] {
        guard let organizations = authClaims?["organizations"] as? [[String: Any]] else {
            return []
        }

        return organizations.compactMap { organization in
            for key in ["title", "name", "display_name"] {
                if let value = organization[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }

            return nil
        }
    }

    private func defaultWorkspaceLabel(for identity: SystemAuthIdentity, plan: String?) -> String {
        if isPersonalPlan(self.displayPlan(plan)) {
            return "Personal"
        }

        if let organizationTitle = identity.organizationTitles.first(where: {
            $0.caseInsensitiveCompare("Personal") != .orderedSame
        }) {
            return organizationTitle
        }

        return "Personal"
    }

    private func resolveWorkspaceName(
        _ payload: [String: Any],
        workspaceItem: WorkspaceItem?,
        identity: SystemAuthIdentity
    ) -> String {
        let fallbackName = workspaceItem?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payloadPlan = payload["plan_type"] as? String ?? identity.planType
        let fallback = fallbackName.isEmpty
            ? self.defaultWorkspaceLabel(for: identity, plan: payloadPlan)
            : fallbackName

        return self.resolveWorkspaceLabel(
            payload: payload,
            fallback: fallback
        )
    }

    private func normalizeWorkspaceAccountID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed.lowercased()
    }

    private func buildRemovableAccountIDs(for accounts: [AccountSnapshot]) -> Set<String> {
        AccountRemovalResolver.removableAccountIDs(
            for: accounts
        )
    }

    private func displayPlan(_ rawPlan: String?) -> String {
        guard let rawPlan, !rawPlan.isEmpty else {
            return "Codex"
        }

        return "Codex \(rawPlan.prefix(1).uppercased())\(rawPlan.dropFirst())"
    }

    private func publishMergedSnapshots(
        _ snapshots: [AccountSnapshot],
        config: PulseConfig,
        systemStateWasRefreshed: Bool = false
    ) {
        let unsuppressedSnapshots = snapshots.filter {
            !self.removalSuppressions.shouldSuppress($0)
        }
        let merged = self.snapshotMerger.merge(
            existing: self.cache,
            incoming: unsuppressedSnapshots,
            systemStateWasRefreshed: systemStateWasRefreshed
        )

        try? self.cacheStore.save(merged)
        self.cache = merged
        self.removableAccountIDs = self.buildRemovableAccountIDs(
            for: merged.accounts
        )
    }

    private func resetAuthRefreshRetry() {
        self.authRetryTask?.cancel()
        self.authRetryTask = nil
        self.authRetryBackoff.reset()
    }

    private func scheduleAuthRefreshRetryIfNeeded() {
        guard self.authRetryTask == nil else {
            return
        }

        // Keep the first retry fast for session transitions, then back off
        // during outages instead of refreshing every account once a second.
        let delay = self.authRetryBackoff.takeDelay()
        self.authRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.authRetryTask = nil
            await self.syncNow(requestKind: .stateChange)
        }
    }

    private func startAuthFileMonitor() {
        let authDirectoryURL = ComuxPaths.codexAuth.deletingLastPathComponent()
        let directoryPath = authDirectoryURL.path(percentEncoded: false)
        let fileDescriptor = open(directoryPath, O_EVTONLY)

        guard fileDescriptor >= 0 else {
            return
        }

        self.authMonitorFileDescriptor = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            let currentSignature = self.currentAuthFileSignature()
            guard currentSignature != self.lastObservedAuthSignature else {
                return
            }

            self.lastObservedAuthSignature = currentSignature
            self.resetAuthRefreshRetry()
            Task { @MainActor in
                await self.syncNow(requestKind: .stateChange)
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else {
                return
            }

            if self.authMonitorFileDescriptor >= 0 {
                close(self.authMonitorFileDescriptor)
                self.authMonitorFileDescriptor = -1
            }
        }

        self.authMonitorSource = source
        source.resume()
    }

    private func currentAuthFileSignature() -> AuthFileSignature? {
        let authPath = ComuxPaths.codexAuth.path(percentEncoded: false)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: authPath) else {
            return nil
        }

        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        return AuthFileSignature(
            modificationDate: modificationDate,
            size: size
        )
    }
}

private struct SystemSnapshotRefresh {
    let snapshots: [AccountSnapshot]
}

private struct AuthFileSignature: Equatable {
    let modificationDate: Date
    let size: Int64
}

struct AccountRemovalSuppressions {
    private var systemAuthIdentities = Set<String>()

    mutating func suppressRemoval(of account: AccountSnapshot) {
        guard AccountRemovalResolver.shouldSuppressRefreshAfterRemoval(account) else {
            return
        }

        self.systemAuthIdentities.insert(AccountRemovalResolver.identity(for: account))
    }

    mutating func clearSystemAuthSuppressions() {
        self.systemAuthIdentities.removeAll()
    }

    func shouldSuppress(_ account: AccountSnapshot) -> Bool {
        AccountRemovalResolver.shouldSuppressRefreshAfterRemoval(account)
            && self.systemAuthIdentities.contains(AccountRemovalResolver.identity(for: account))
    }
}

enum AccountRemovalResolver {
    private static let liveSystemAuthSource = "live system auth"

    static func identity(for account: AccountSnapshot) -> String {
        AccountIdentity.key(for: account).storageKey
    }

    static func shouldSuppressRefreshAfterRemoval(_ account: AccountSnapshot) -> Bool {
        account.source == self.liveSystemAuthSource
    }

    static func configAccountID(for account: AccountSnapshot, in config: PulseConfig) -> String? {
        let accountIdentity = identity(for: account)
        return config.accounts.first(where: {
            AccountIdentity.key(for: $0).storageKey == accountIdentity
        })?.id
    }

    static func removableAccountIDs(for accounts: [AccountSnapshot]) -> Set<String> {
        Set(accounts.map(\.accountId))
    }

    static func remove(
        _ account: AccountSnapshot,
        from cache: CachePayload,
        config: PulseConfig
    ) -> (cache: CachePayload, config: PulseConfig) {
        let removedIdentity = identity(for: account)
        let configAccountID = configAccountID(for: account, in: config)
        let filteredConfigAccounts = config.accounts.filter { configAccount in
            guard let configAccountID else {
                return true
            }

            return configAccount.id != configAccountID
        }
        let filteredAccounts = cache.accounts.filter { candidate in
            candidate.accountId != account.accountId && identity(for: candidate) != removedIdentity
        }

        return (
            cache: CachePayload(
                meta: CacheMeta(source: cache.meta.source),
                accounts: filteredAccounts
            ),
            config: PulseConfig(
                pollIntervalSeconds: config.pollIntervalSeconds,
                accounts: filteredConfigAccounts
            )
        )
    }
}
