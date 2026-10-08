import XCTest
@testable import Comux

final class AccountSnapshotMergerTests: XCTestCase {
    func testPartialWorkspaceRefreshUpdatesCurrentUsageAndPreservesFailedWorkspaceHistory() async throws {
        let cachedCurrent = self.makeSnapshot(
            accountId: "person@example.com::personal-workspace",
            email: "person@example.com",
            workspaceId: "personal-workspace",
            workspaceLabel: "Personal",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            weeklyUsedPercentage: 30
        )
        let cachedRemote = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1",
            weeklyUsedPercentage: 64
        )
        let refreshedCurrent = self.makeSnapshot(
            accountId: cachedCurrent.accountId,
            email: cachedCurrent.email,
            workspaceId: cachedCurrent.workspaceId,
            workspaceLabel: cachedCurrent.workspaceLabel,
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-28T01:00:00Z",
            weeklyUsedPercentage: 11
        )
        let remoteSnapshots: [AccountSnapshot] = try await BoundedConcurrency.mapSuccessful(
            [cachedRemote],
            limit: RefreshConcurrencyPolicy.maximumConcurrentFetches
        ) { _ in
            throw PulseError.invalidUsageResponse
        }

        let merged = AccountSnapshotMerger().merge(
            existing: CachePayload(meta: CacheMeta(source: "test"), accounts: [cachedCurrent, cachedRemote]),
            incoming: [refreshedCurrent] + remoteSnapshots,
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 2)
        let remote = try XCTUnwrap(merged.accounts.first(where: { $0.id == cachedRemote.id }))
        XCTAssertEqual(remote.usageWindows, cachedRemote.usageWindows)
        XCTAssertEqual(remote.lastSyncedAt, cachedRemote.lastSyncedAt)
        XCTAssertEqual(remote.workspaceId, cachedRemote.workspaceId)
        XCTAssertEqual(remote.isCurrentSystemAccount, false)
        let current = try XCTUnwrap(merged.accounts.first(where: { $0.isCurrentSystemAccount == true }))
        XCTAssertEqual(current.id, cachedCurrent.id)
        XCTAssertEqual(remainingPercentage(for: current.weeklyWindow), 89)
        XCTAssertEqual(current.lastSyncedAt, refreshedCurrent.lastSyncedAt)
    }

    func testTransientCookieOnlyRefreshPreservesCurrentSystemSeat() {
        let merger = AccountSnapshotMerger()
        let existingActive = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )
        let cookieSnapshot = self.makeSnapshot(
            accountId: "person@example.com::cookie-seat",
            email: "person@example.com",
            workspaceId: nil,
            workspaceLabel: "Cookie Seat",
            source: "native cookie sync",
            isCurrentSystemAccount: false
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [existingActive]
            ),
            incoming: [cookieSnapshot],
            systemStateWasRefreshed: false
        )

        XCTAssertEqual(merged.accounts.count, 2)
        XCTAssertEqual(
            merged.accounts.first(where: { $0.accountId == existingActive.accountId })?.isCurrentSystemAccount,
            true
        )
    }

    func testRefreshedEmptySystemStateClearsCurrentSystemSeat() {
        let merger = AccountSnapshotMerger()
        let existingActive = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [existingActive]
            ),
            incoming: [],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].isCurrentSystemAccount, false)
    }

    func testSeatSwapFallbackPreservesWorkspaceBackedMetadata() {
        let merger = AccountSnapshotMerger()
        let existingWorkspaceSeat = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            weeklyAvailable: true
        )
        let incomingFallbackSeat = self.makeSnapshot(
            accountId: "person@example.com::personal",
            email: "person@example.com",
            workspaceId: nil,
            workspaceLabel: "Personal",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            weeklyAvailable: false
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [existingWorkspaceSeat]
            ),
            incoming: [incomingFallbackSeat],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].accountId, existingWorkspaceSeat.accountId)
        XCTAssertEqual(merged.accounts[0].workspaceId, existingWorkspaceSeat.workspaceId)
        XCTAssertEqual(merged.accounts[0].workspaceLabel, existingWorkspaceSeat.workspaceLabel)
        XCTAssertEqual(merged.accounts[0].isCurrentSystemAccount, true)
    }

    func testCoexistingSameEmailWorkspaceSeatsRemainDistinct() {
        let merger = AccountSnapshotMerger()
        let workspaceA = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )
        let workspaceB = self.makeSnapshot(
            accountId: "person@example.com::workspace-b",
            email: "person@example.com",
            workspaceId: "workspace-b",
            workspaceLabel: "Workspace B",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: []
            ),
            incoming: [workspaceA, workspaceB],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 2)
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == workspaceA.accountId }))
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == workspaceB.accountId }))
    }

    func testSameEmailNoWorkspaceWorkspaceAndNoSeatWorkspaceAccountsCoexist() {
        let merger = AccountSnapshotMerger()
        let noWorkspace = self.makeSnapshot(
            accountId: "orangesagocream@gmail.com",
            email: "orangesagocream@gmail.com",
            workspaceId: nil,
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1"
        )
        let workspace = self.makeSnapshot(
            accountId: "orangesagocream@gmail.com::workspace-a",
            email: "orangesagocream@gmail.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            plan: "Codex Team",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )
        let noUsageWorkspace = self.makeSnapshot(
            accountId: "orangesagocream@gmail.com::8ccae9fa-c4dc-4d0b-bfb6-8cf230d7e084",
            email: "orangesagocream@gmail.com",
            workspaceId: "8ccae9fa-c4dc-4d0b-bfb6-8cf230d7e084",
            workspaceLabel: "Kiwi",
            plan: "Codex Self_serve_business_usage_based",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "google-oauth2|111509752519153701574",
            weeklyAvailable: false,
            weeklyUsedMinutes: 0,
            weeklyLimitMinutes: 0,
            weeklyUsedPercentage: 0,
            weeklyResetsAt: "",
            rollingAvailable: false,
            rollingUsedMinutes: 0,
            rollingLimitMinutes: 0,
            rollingUsedPercentage: 0,
            rollingResetsAt: ""
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: []
            ),
            incoming: [noWorkspace, workspace, noUsageWorkspace],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 3)
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == noWorkspace.accountId }))
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == workspace.accountId }))
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == noUsageWorkspace.accountId }))
        XCTAssertEqual(
            merged.accounts.first(where: { $0.accountId == noUsageWorkspace.accountId })?.weeklyWindow.limitMinutes,
            0
        )
        XCTAssertEqual(
            merged.accounts.first(where: { $0.accountId == noUsageWorkspace.accountId })?.rollingWindow.available,
            false
        )
    }

    func testStaleWorkspaceSeatLossPreservesCachedUsageWindows() {
        let merger = AccountSnapshotMerger()
        let existingSeatedWorkspace = self.makeSnapshot(
            accountId: "orangesagocream@gmail.com::8ccae9fa-c4dc-4d0b-bfb6-8cf230d7e084",
            email: "orangesagocream@gmail.com",
            workspaceId: "8ccae9fa-c4dc-4d0b-bfb6-8cf230d7e084",
            workspaceLabel: "Kiwi",
            plan: "Codex Team",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "google-oauth2|111509752519153701574",
            lastSyncedAt: "2026-05-28T08:00:00Z",
            weeklyAvailable: true,
            weeklyUsedMinutes: 7762,
            weeklyLimitMinutes: 10080,
            weeklyUsedPercentage: 77,
            weeklyResetsAt: "2026-05-31T01:23:17Z",
            rollingAvailable: true,
            rollingUsedMinutes: 204,
            rollingLimitMinutes: 300,
            rollingUsedPercentage: 68,
            rollingResetsAt: "2026-05-26T06:41:51Z"
        )
        let staleSeatLoss = self.makeSnapshot(
            accountId: existingSeatedWorkspace.accountId,
            email: existingSeatedWorkspace.email,
            workspaceId: existingSeatedWorkspace.workspaceId,
            workspaceLabel: existingSeatedWorkspace.workspaceLabel,
            plan: "Codex Self_serve_business_usage_based",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: existingSeatedWorkspace.systemAuthProfileId,
            lastSyncedAt: "2026-05-29T08:00:00Z",
            weeklyAvailable: false,
            weeklyUsedMinutes: 0,
            weeklyLimitMinutes: 0,
            weeklyUsedPercentage: 0,
            weeklyResetsAt: "",
            rollingAvailable: false,
            rollingUsedMinutes: 0,
            rollingLimitMinutes: 0,
            rollingUsedPercentage: 0,
            rollingResetsAt: ""
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [existingSeatedWorkspace]
            ),
            incoming: [staleSeatLoss],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 1)
        XCTAssertEqual(merged.accounts[0].accountId, existingSeatedWorkspace.accountId)
        XCTAssertEqual(merged.accounts[0].lastSyncedAt, staleSeatLoss.lastSyncedAt)
        XCTAssertEqual(merged.accounts[0].plan, existingSeatedWorkspace.plan)
        XCTAssertEqual(merged.accounts[0].weeklyWindow.available, true)
        XCTAssertEqual(merged.accounts[0].weeklyWindow.usedMinutes, 7762)
        XCTAssertEqual(merged.accounts[0].weeklyWindow.limitMinutes, 10080)
        XCTAssertEqual(merged.accounts[0].weeklyWindow.resetsAt, "2026-05-31T01:23:17Z")
        XCTAssertEqual(merged.accounts[0].rollingWindow.available, true)
        XCTAssertEqual(merged.accounts[0].rollingWindow.usedMinutes, 204)
        XCTAssertEqual(merged.accounts[0].rollingWindow.limitMinutes, 300)
        XCTAssertEqual(merged.accounts[0].rollingWindow.resetsAt, "2026-05-26T06:41:51Z")
    }

    func testStablePersonalWorkspaceSupersedesStaleUnscopedPersonalSystemSeat() {
        let merger = AccountSnapshotMerger()
        let stalePersonal = self.makeSnapshot(
            accountId: "person@example.com",
            email: "person@example.com",
            workspaceId: nil,
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1"
        )
        let currentPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-abc",
            email: "person@example.com",
            workspaceId: "user-abc",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [stalePersonal]
            ),
            incoming: [currentPersonal],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.map(\.accountId), [currentPersonal.accountId])
        XCTAssertEqual(merged.accounts[0].isCurrentSystemAccount, true)
    }

    func testLoadedPersonalAliasCompactionKeepsNewerScopedPersonalSeat() {
        let merger = AccountSnapshotMerger()
        let stalePersonal = self.makeSnapshot(
            accountId: "person@example.com",
            email: "person@example.com",
            workspaceId: nil,
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-26T00:00:00Z"
        )
        let scopedPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-abc",
            email: "person@example.com",
            workspaceId: "user-abc",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-29T00:00:00Z"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: []
            ),
            incoming: [stalePersonal, scopedPersonal],
            systemStateWasRefreshed: false
        )

        XCTAssertEqual(merged.accounts.map(\.accountId), [scopedPersonal.accountId])
        XCTAssertEqual(merged.accounts[0].weeklyWindow.usedMinutes, scopedPersonal.weeklyWindow.usedMinutes)
    }

    func testWorkspaceBackedTeamSeatDoesNotSupersedeUnscopedPersonalSystemSeat() {
        let merger = AccountSnapshotMerger()
        let personal = self.makeSnapshot(
            accountId: "person@example.com",
            email: "person@example.com",
            workspaceId: nil,
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1"
        )
        let team = self.makeSnapshot(
            accountId: "person@example.com::workspace-a",
            email: "person@example.com",
            workspaceId: "workspace-a",
            workspaceLabel: "Workspace A",
            plan: "Codex Team",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [personal]
            ),
            incoming: [team],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 2)
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == personal.accountId }))
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == team.accountId }))
    }

    func testRotatedPersonalWorkspaceIDSupersedesOlderPersonalSystemSeat() {
        let merger = AccountSnapshotMerger()
        let oldPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-old",
            email: "person@example.com",
            workspaceId: "user-old",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-27T00:00:00Z"
        )
        let currentPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-new",
            email: "person@example.com",
            workspaceId: "user-new",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-28T00:00:00Z"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [oldPersonal]
            ),
            incoming: [currentPersonal],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.map(\.accountId), [currentPersonal.accountId])
    }

    func testPersonalSystemSeatCanSupersedeAfterProfileIDFormatChanges() {
        let merger = AccountSnapshotMerger()
        let oldPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-old",
            email: "person@example.com",
            workspaceId: "user-old",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "old-provider|profile-1",
            lastSyncedAt: "2026-05-27T00:00:00Z"
        )
        let currentPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-new",
            email: "person@example.com",
            workspaceId: "user-new",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "new-provider|profile-1",
            lastSyncedAt: "2026-05-28T00:00:00Z"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [oldPersonal]
            ),
            incoming: [currentPersonal],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.map(\.accountId), [currentPersonal.accountId])
    }

    func testNewerNonCurrentPersonalSnapshotDoesNotSupersedeCurrentSystemSeat() {
        let merger = AccountSnapshotMerger()
        let currentPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-current",
            email: "person@example.com",
            workspaceId: "user-current",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: true,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-27T00:00:00Z"
        )
        let newerNonCurrentPersonal = self.makeSnapshot(
            accountId: "person@example.com::user-newer",
            email: "person@example.com",
            workspaceId: "user-newer",
            workspaceLabel: "",
            plan: "Codex Free",
            source: "live system auth",
            isCurrentSystemAccount: false,
            systemAuthProfileId: "profile-1",
            lastSyncedAt: "2026-05-28T00:00:00Z"
        )

        let merged = merger.merge(
            existing: CachePayload(
                meta: CacheMeta(source: "test"),
                accounts: [currentPersonal]
            ),
            incoming: [newerNonCurrentPersonal],
            systemStateWasRefreshed: true
        )

        XCTAssertEqual(merged.accounts.count, 2)
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == currentPersonal.accountId }))
        XCTAssertNotNil(merged.accounts.first(where: { $0.accountId == newerNonCurrentPersonal.accountId }))
    }

    private func makeSnapshot(
        accountId: String,
        email: String,
        workspaceId: String?,
        workspaceLabel: String,
        plan: String = "Codex Team",
        source: String,
        isCurrentSystemAccount: Bool?,
        systemAuthProfileId: String? = nil,
        lastSyncedAt: String = "2026-05-28T00:00:00Z",
        weeklyAvailable: Bool = true,
        weeklyUsedMinutes: Int = 10,
        weeklyLimitMinutes: Int = 100,
        weeklyUsedPercentage: Double = 10,
        weeklyResetsAt: String = "2026-05-29T00:00:00Z",
        rollingAvailable: Bool = true,
        rollingUsedMinutes: Int = 5,
        rollingLimitMinutes: Int = 50,
        rollingUsedPercentage: Double = 10,
        rollingResetsAt: String = "2026-05-28T05:00:00Z"
    ) -> AccountSnapshot {
        AccountSnapshot(
            accountId: accountId,
            label: email,
            email: email,
            workspaceId: workspaceId,
            workspaceLabel: workspaceLabel,
            plan: plan,
            source: source,
            systemAuthProfileId: systemAuthProfileId,
            isCurrentSystemAccount: isCurrentSystemAccount,
            lastSyncedAt: lastSyncedAt,
            weeklyWindow: UsageWindow(
                available: weeklyAvailable,
                label: "Weekly window",
                usedMinutes: weeklyUsedMinutes,
                limitMinutes: weeklyLimitMinutes,
                usedPercentage: weeklyUsedPercentage,
                resetsAt: weeklyResetsAt
            ),
            rollingWindow: UsageWindow(
                available: rollingAvailable,
                label: "Rolling 5-hour window",
                usedMinutes: rollingUsedMinutes,
                limitMinutes: rollingLimitMinutes,
                usedPercentage: rollingUsedPercentage,
                resetsAt: rollingResetsAt
            )
        )
    }
}
