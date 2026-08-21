// THESIS: One calm desk shows what matters across personal apps without becoming another source of truth.
// OWN-WORLD: Pace graphite surfaces, native system type, thin dividers, and electric blue only for safe local action.
// STORY: Scan Calorie and Kith, ask one cross-app question, act, then verify provenance and undo in Activity.
// FIRST VIEWPORT: A compact Today/Ask/Activity/Connections switch leads into two source-owned status cards and one refresh control.
// FORM: An operating extension of the existing Command Center; preserve lane, dense native management composition.

import AuthenticationServices
import PersonalSyncKit
import SwiftUI

private enum PacePersonalControlPlaneSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case ask = "Ask"
    case activity = "Activity"
    case connections = "Connections"

    var id: String { rawValue }
}

struct PacePersonalControlPlaneView: View {
    @ObservedObject private var store: PacePersonalControlPlaneStore
    @State private var selectedSection = PacePersonalControlPlaneSection.today
    @State private var question = "What should I pay attention to today?"
    @State private var appleNonce = AppleNonce.make()

    init(store: PacePersonalControlPlaneStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Picker("Personal control plane section", selection: $selectedSection) {
                    ForEach(PacePersonalControlPlaneSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)

                Spacer()

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)
                .pointerCursor(isEnabled: !store.isRefreshing)
                .accessibilityHint("Refreshes Calorie, Kith, activity, and connection freshness")
            }

            if let connectionMessage = store.connectionMessage {
                Label(connectionMessage, systemImage: "link")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }

            Group {
                switch selectedSection {
                case .today:
                    today
                case .ask:
                    ask
                case .activity:
                    activity
                case .connections:
                    connections
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if store.snapshots.isEmpty {
                await store.refresh()
            }
        }
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("What needs attention")
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                Text("Source apps stay canonical")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            if store.snapshots.isEmpty {
                PacePersonalLoadingState()
            } else {
                ForEach(PacePersonalApplication.allCases) { application in
                    if let snapshot = store.snapshots[application] {
                        PacePersonalApplicationCard(
                            snapshot: snapshot,
                            onSuggestedAction: {
                                Task { await store.performSuggestedAction(for: application) }
                            },
                            onOpenSource: { store.openSourceApplication(application) },
                            onConnect: {
                                selectedSection = .connections
                            }
                        )
                    }
                }
            }
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask across connected apps")
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Pace selects only relevant connectors and keeps the source trail visible.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            HStack(alignment: .center, spacing: 10) {
                TextField("Ask about today", text: $question)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.body)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(DS.Colors.surfaceInset)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    }
                    .onSubmit { submitQuestion() }

                Button(action: submitQuestion) {
                    Label(store.isAnswering ? "Checking" : "Ask", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Colors.localSignal)
                .disabled(store.isAnswering || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor(isEnabled: !store.isAnswering)
            }

            if let answer = store.answer {
                VStack(alignment: .leading, spacing: 14) {
                    Text(answer.text)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .textSelection(.enabled)

                    HStack(spacing: 7) {
                        Text("Consulted")
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(DS.Colors.textTertiary)
                        ForEach(answer.sources) { source in
                            PacePersonalSourceTag(application: source)
                        }
                    }

                    ForEach(answer.limitations, id: \.self) { limitation in
                        Label(limitation, systemImage: "exclamationmark.triangle")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.warning)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try one")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.Colors.textTertiary)
                    ForEach([
                        "What should I pay attention to today?",
                        "Record that I spoke to Rahul and log my usual breakfast.",
                    ], id: \.self) { example in
                        Button(example) {
                            question = example
                            submitQuestion()
                        }
                        .buttonStyle(.plain)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.localSignal)
                        .pointerCursor()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surfaceRaised.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Actions through Pace")
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Pending is not success. Every mutation keeps its instruction, source, result, and undo contract.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            if store.activity.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("No Pace actions yet", systemImage: "checklist")
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Use a suggested action on Today. Reads never appear here because they do not change a source app.")
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.activity) { record in
                        PacePersonalActivityRow(
                            record: record,
                            onUndo: record.result.undoInformation == nil
                                ? nil
                                : { Task { await store.undo(record) } }
                        )
                        if record.id != store.activity.last?.id {
                            Divider().background(DS.Colors.borderSubtle)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                }
            }
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Personal Platform")
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("One Apple identity, explicit domain scopes, and visible synchronization freshness.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label(
                    store.connections.message,
                    systemImage: store.connections.isConnected ? "checkmark.icloud.fill" : "icloud.slash"
                )
                .font(DS.Typography.headline)
                .foregroundStyle(store.connections.isConnected ? DS.Colors.success : DS.Colors.textSecondary)

                if let email = store.connections.identityEmail {
                    Text(email)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                }

                connectionRow(
                    title: "Calorie",
                    detail: "Authenticated domain service",
                    synchronizedAt: store.connections.calorieSynchronizedAt
                )
                Divider().background(DS.Colors.borderSubtle)
                connectionRow(
                    title: "Kith",
                    detail: "iPhone local JSON → Cloudflare",
                    synchronizedAt: store.connections.kithSynchronizedAt
                )

                if store.connections.isConnected {
                    Text(store.connections.scopes.joined(separator: " · "))
                        .font(DS.Typography.metadata)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .textSelection(.enabled)
                    Button("Disconnect this Mac", role: .destructive) {
                        Task { await store.disconnect() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    SignInWithAppleButton(.continue) { request in
                        appleNonce = AppleNonce.make()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AppleNonce.digest(appleNonce)
                    } onCompletion: { result in
                        guard
                            case let .success(authorization) = result,
                            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                            let tokenData = credential.identityToken,
                            let token = String(data: tokenData, encoding: .utf8)
                        else {
                            return
                        }
                        let payload = AppleIdentityCredential(
                            identityToken: token,
                            nonce: appleNonce,
                            email: credential.email,
                            firstName: credential.fullName?.givenName,
                            lastName: credential.fullName?.familyName
                        )
                        Task { await store.connect(with: payload) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: 260, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            }
        }
    }

    private func connectionRow(title: String, detail: String, synchronizedAt: Date?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.Typography.calloutStrong)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer()
            Text(synchronizedAt.map {
                "Synced \($0.formatted(.relative(presentation: .named)))"
            } ?? "Awaiting first sync")
                .font(DS.Typography.caption)
                .foregroundStyle(synchronizedAt == nil ? DS.Colors.warning : DS.Colors.textTertiary)
        }
    }

    private func submitQuestion() {
        Task { await store.ask(question) }
    }
}

private struct PacePersonalApplicationCard: View {
    let snapshot: PaceApplicationSnapshot
    let onSuggestedAction: () -> Void
    let onOpenSource: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: snapshot.source.application == .calorie ? "fork.knife" : "person.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.localSignal)
                    .frame(width: 26, height: 26)
                    .background(DS.Colors.surfaceInset)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.source.application.displayName)
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(freshnessText)
                        .font(DS.Typography.caption)
                        .foregroundStyle(freshnessColor)
                }

                Spacer()

                Button("Open \(snapshot.source.application.displayName)", action: onOpenSource)
                    .buttonStyle(.plain)
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .pointerCursor()
            }

            Text(snapshot.status)
                .font(DS.Typography.bodyStrong)
                .foregroundStyle(DS.Colors.textPrimary)

            domainMetrics

            ForEach(snapshot.alerts.prefix(2), id: \.self) { alert in
                Label(alert, systemImage: "exclamationmark.circle")
                    .font(DS.Typography.caption)
                    .foregroundStyle(snapshot.source.connectorState == .unavailable
                        ? DS.Colors.textSecondary
                        : DS.Colors.warning)
            }

            HStack(spacing: 9) {
                if let action = snapshot.suggestedAction {
                    Button(action.title, action: onSuggestedAction)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Colors.localSignal)
                        .pointerCursor()
                } else if snapshot.source.connectorState == .unavailable {
                    Button("Connect Personal Platform", action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Colors.localSignal)
                        .pointerCursor()
                } else {
                    Button("Open to refresh", action: onOpenSource)
                        .buttonStyle(.bordered)
                        .pointerCursor()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snapshot.source.application.displayName), \(snapshot.status)")
    }

    @ViewBuilder
    private var domainMetrics: some View {
        switch snapshot.domain {
        case .calorie(let summary):
            HStack(spacing: 18) {
                metric(value: summary.proteinGrams.formatted(.number.precision(.fractionLength(0))), label: "g protein")
                metric(value: summary.calories.formatted(.number.precision(.fractionLength(0))), label: "kcal")
                metric(value: (summary.waterMillilitres / 1_000).formatted(.number.precision(.fractionLength(1))), label: "L water")
            }
        case .kith(let summary):
            HStack(spacing: 18) {
                metric(value: "\(summary.people.count)", label: "people")
                metric(value: "\(summary.attentionRequired.count)", label: "need attention")
                metric(value: summary.attentionRequired.first?.name ?? "—", label: "next follow-up")
            }
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DS.Typography.calloutStrong)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private var freshnessText: String {
        switch snapshot.source.connectorState {
        case .current:
            "Updated \(snapshot.source.generatedAt.formatted(.relative(presentation: .named)))"
        case .stale:
            "Stale · \(snapshot.source.generatedAt.formatted(.relative(presentation: .named)))"
        case .unavailable:
            "Not connected"
        }
    }

    private var freshnessColor: Color {
        switch snapshot.source.connectorState {
        case .current: DS.Colors.success
        case .stale: DS.Colors.warning
        case .unavailable: DS.Colors.textTertiary
        }
    }
}

private struct PacePersonalActivityRow: View {
    let record: PaceActivityRecord
    let onUndo: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(record.request.action.title)
                        .font(DS.Typography.calloutStrong)
                        .foregroundStyle(DS.Colors.textPrimary)
                    PacePersonalSourceTag(application: record.request.sourceApplication)
                }
                Text(record.result.message)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(record.request.requestedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Typography.metadata)
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            Spacer()

            if let onUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch record.result.status {
        case .pending: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .undone: "arrow.uturn.backward.circle.fill"
        }
    }

    private var statusColor: Color {
        switch record.result.status {
        case .pending: DS.Colors.warning
        case .succeeded: DS.Colors.success
        case .failed: DS.Colors.failure
        case .undone: DS.Colors.textSecondary
        }
    }
}

private struct PacePersonalSourceTag: View {
    let application: PacePersonalApplication

    var body: some View {
        Text(application.displayName)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(DS.Colors.surfaceInset)
            .clipShape(Capsule())
    }
}

private struct PacePersonalLoadingState: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading Calorie and Kith summaries…")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
    }
}
