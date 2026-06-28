import SwiftUI
import StoreKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Pro Upgrade Sheet

struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager
    private let source: PaywallSource
    private let onDismiss: (() -> Void)?

    @State private var selectedPlan: ProPlanKind = .yearly
    @State private var showSuccess = false
    @State private var alertInfo: AlertInfo?
    @State private var showCancelSubscriptionAlert = false
    @State private var showManageSubscription = false

    private struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isRestore: Bool
    }

    init(source: PaywallSource = .general, onDismiss: (() -> Void)? = nil) {
        self.source = source
        self.onDismiss = onDismiss
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            sheetContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(source.paywallTitle)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(source.paywallSubtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        #else
        macSheetContent
        #endif
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                contentStack
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.visible)

            purchaseFooter
        }
        .background(sheetBackground.ignoresSafeArea())
        .task {
            storeManager.notePaywallPresented(source: source)
            storeManager.requestProductLoad {
                selectedPlan = defaultPlan
            }
        }
        .onChangeCompat(of: storeManager.purchaseState) { newState in
            handlePurchaseStateChange(newState)
        }
        .onChangeCompat(of: storeManager.restoreState) { newState in
            handleRestoreStateChange(newState)
        }
        .overlay {
            if showSuccess {
                successOverlay
            }
        }
        .alert(alertInfo?.title ?? "", isPresented: .init(
            get: { alertInfo != nil },
            set: { isPresented in
                if !isPresented {
                    if alertInfo?.isRestore == true {
                        storeManager.dismissRestoreResult()
                    }
                    alertInfo = nil
                }
            }
        ), presenting: alertInfo) { info in
            Button("OK") {
                if info.isRestore {
                    storeManager.dismissRestoreResult()
                }
                alertInfo = nil
            }
        } message: { info in
            Text(info.message)
        }
        .alert(String(localized: "Cancel Subscription?"), isPresented: $showCancelSubscriptionAlert) {
            Button(String(localized: "Manage Subscription")) {
                openSubscriptionManagement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    close()
                }
            }
            Button(String(localized: "Later"), role: .cancel) {
                close()
            }
        } message: {
            Text("You now have lifetime access. You should cancel your existing subscription to avoid being charged.")
        }
        #if os(iOS)
        .manageSubscriptionsSheetCompat(
            isPresented: $showManageSubscription,
            subscriptionGroupID: VVTermProducts.subscriptionGroupId
        )
        #endif
    }

    #if os(macOS)
    private var macSheetContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                contentStack
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)

            purchaseFooter
        }
        .frame(
            minWidth: 500,
            idealWidth: 520,
            maxWidth: .infinity,
            minHeight: 620,
            idealHeight: 780,
            maxHeight: .infinity
        )
        .background(sheetBackground)
        .background(ProUpgradeWindowConfigurator(source: source))
        .task {
            storeManager.notePaywallPresented(source: source)
            storeManager.requestProductLoad {
                selectedPlan = defaultPlan
            }
        }
        .onChangeCompat(of: storeManager.purchaseState) { newState in
            handlePurchaseStateChange(newState)
        }
        .onChangeCompat(of: storeManager.restoreState) { newState in
            handleRestoreStateChange(newState)
        }
        .overlay {
            if showSuccess {
                successOverlay
            }
        }
        .alert(alertInfo?.title ?? "", isPresented: .init(
            get: { alertInfo != nil },
            set: { isPresented in
                if !isPresented {
                    if alertInfo?.isRestore == true {
                        storeManager.dismissRestoreResult()
                    }
                    alertInfo = nil
                }
            }
        ), presenting: alertInfo) { info in
            Button("OK") {
                if info.isRestore {
                    storeManager.dismissRestoreResult()
                }
                alertInfo = nil
            }
        } message: { info in
            Text(info.message)
        }
        .alert(String(localized: "Cancel Subscription?"), isPresented: $showCancelSubscriptionAlert) {
            Button(String(localized: "Manage Subscription")) {
                openSubscriptionManagement()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    close()
                }
            }
            Button(String(localized: "Later"), role: .cancel) {
                close()
            }
        } message: {
            Text("You now have lifetime access. You should cancel your existing subscription to avoid being charged.")
        }
    }
    #endif

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            comparisonSection
            planSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: String(localized: "Compare plans"))

            NativeSectionCard(padding: 0) {
                ComparisonTable(rows: comparisonRows)
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: String(localized: "Choose a plan"))

            if availablePlans.isEmpty {
                NativeSectionCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading plans...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 82)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(availablePlans) { plan in
                        if let product = product(for: plan) {
                            PlanSelectionCard(
                                product: product,
                                plan: plan,
                                isSelected: selectedPlan == plan
                            ) {
                                selectedPlan = plan
                            }
                        }
                    }
                }
            }
        }
    }

    private var purchaseFooter: some View {
        VStack(spacing: 5) {
            Button {
                if let product = selectedProduct {
                    storeManager.requestPurchase(of: product)
                }
            } label: {
                ZStack {
                    Text(subscribeButtonTitle)
                        .fontWeight(.semibold)
                        .opacity(storeManager.purchaseState == .purchasing ? 0 : 1)

                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)

                        Text("Processing...")
                            .fontWeight(.semibold)
                    }
                    .opacity(storeManager.purchaseState == .purchasing ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProduct == nil)
            .allowsHitTesting(storeManager.purchaseState != .purchasing)

            footerSupportRow

            Text(selectedPlan == .lifetime ? String(localized: "One-time purchase. No subscription renewal.") : String(localized: "Auto-renews until canceled."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        #if os(macOS)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.55)
        }
        .background(sheetBackground)
        #else
        .background(.bar)
        #endif
    }

    private var footerSupportRow: some View {
        HStack(spacing: 6) {
            restoreButton

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Terms", url: "https://vvterm.com/terms")

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Privacy", url: "https://vvterm.com/privacy")

            Text(verbatim: "•")
                .foregroundStyle(.tertiary)

            legalLink(title: "Refund", url: "https://vvterm.com/refund")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var restoreButton: some View {
        Button {
            storeManager.requestRestorePurchases()
        } label: {
            HStack(spacing: 8) {
                if storeManager.restoreState == .restoring {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .imageScale(.small)
                }
                Text(storeManager.restoreState == .restoring
                     ? String(localized: "Restoring...")
                     : String(localized: "Restore Purchases"))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(storeManager.restoreState == .restoring)
    }

    // MARK: - Success Overlay

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)

                Text("Welcome to Pro")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("You now have unlimited access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
        .transition(.opacity)
    }

    // MARK: - Products

    private var availablePlans: [ProPlanKind] {
        ProPlanKind.displayOrder.filter { product(for: $0) != nil }
    }

    private var selectedProduct: Product? {
        product(for: selectedPlan) ?? product(for: defaultPlan)
    }

    private var defaultPlan: ProPlanKind {
        if storeManager.yearlyProduct != nil { return .yearly }
        if storeManager.monthlyProduct != nil { return .monthly }
        if storeManager.lifetimeProduct != nil { return .lifetime }
        return .yearly
    }

    private func product(for plan: ProPlanKind) -> Product? {
        switch plan {
        case .monthly:
            return storeManager.monthlyProduct
        case .yearly:
            return storeManager.yearlyProduct
        case .lifetime:
            return storeManager.lifetimeProduct
        }
    }

    private var subscribeButtonTitle: String {
        guard let product = selectedProduct else { return String(localized: "Select a Plan") }
        if product.id == VVTermProducts.proLifetime {
            return String(format: String(localized: "Buy %@"), product.displayPrice)
        }
        return String(format: String(localized: "Subscribe for %@"), product.displayPrice)
    }

    // MARK: - Comparison

    private var comparisonRows: [ComparisonFeature] {
        [
            ComparisonFeature(
                icon: "server.rack",
                title: String(localized: "Servers"),
                free: .number(String(FreeTierLimits.maxServers)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited servers"))
            ),
            ComparisonFeature(
                icon: "square.stack.3d.up",
                title: String(localized: "Workspaces"),
                free: .number(String(FreeTierLimits.maxWorkspaces)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited workspaces"))
            ),
            ComparisonFeature(
                icon: "rectangle.stack",
                title: String(localized: "Connections"),
                free: .number(String(FreeTierLimits.maxTabs)),
                pro: .unlimited(accessibilityLabel: String(localized: "Multiple connections"))
            ),
            ComparisonFeature(
                icon: "doc.on.doc",
                title: String(localized: "File tabs"),
                free: .number(String(FreeTierLimits.maxFileTabs)),
                pro: .unlimited(accessibilityLabel: String(localized: "Multiple file tabs"))
            ),
            ComparisonFeature(
                icon: "rectangle.split.2x1",
                title: String(localized: "Split panes"),
                free: .notIncluded(accessibilityLabel: String(localized: "Split panes not included on Free")),
                pro: .included(accessibilityLabel: String(localized: "Split panes included on Pro"))
            ),
            ComparisonFeature(
                icon: "command",
                title: String(localized: "Custom actions"),
                free: .number(String(FreeTierLimits.maxCustomActions)),
                pro: .unlimited(accessibilityLabel: String(localized: "Unlimited custom actions"))
            ),
            ComparisonFeature(
                icon: "terminal",
                title: String(localized: "SSH terminal"),
                free: .included(accessibilityLabel: String(localized: "SSH terminal included on Free")),
                pro: .included(accessibilityLabel: String(localized: "SSH terminal included on Pro"))
            ),
            ComparisonFeature(
                icon: "folder",
                title: String(localized: "SFTP browser"),
                free: .included(accessibilityLabel: String(localized: "SFTP browser included on Free")),
                pro: .included(accessibilityLabel: String(localized: "SFTP browser included on Pro"))
            ),
            ComparisonFeature(
                icon: "icloud",
                title: String(localized: "iCloud sync"),
                free: .included(accessibilityLabel: String(localized: "iCloud sync included on Free")),
                pro: .included(accessibilityLabel: String(localized: "iCloud sync included on Pro"))
            ),
            ComparisonFeature(
                icon: "chart.bar.xaxis",
                title: String(localized: "Server stats"),
                free: .included(accessibilityLabel: String(localized: "Server stats included on Free")),
                pro: .included(accessibilityLabel: String(localized: "Server stats included on Pro"))
            ),
            ComparisonFeature(
                icon: "paintbrush",
                title: String(localized: "Environments"),
                free: .text(String(localized: "Built-in"), emphasized: false),
                pro: .text(String(localized: "Custom"), emphasized: true)
            )
        ]
    }

    // MARK: - State Change Handlers

    private func handlePurchaseStateChange(_ newState: PurchaseState) {
        switch newState {
        case .purchased:
            withAnimation(.easeInOut(duration: 0.3)) {
                showSuccess = true
            }
            if storeManager.lastPurchasedProductId == VVTermProducts.proLifetime,
               storeManager.hasActiveSubscriptionWithLifetime {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSuccess = false
                    showCancelSubscriptionAlert = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    close()
                    storeManager.requestReviewAfterPurchase()
                }
            }
        case .failed(let message):
            alertInfo = AlertInfo(
                title: String(localized: "Purchase Failed"),
                message: message,
                isRestore: false
            )
        default:
            break
        }
    }

    private func handleRestoreStateChange(_ newState: RestoreState) {
        switch newState {
        case .restored(let hasAccess):
            alertInfo = AlertInfo(
                title: String(localized: "Restore Purchases"),
                message: hasAccess
                    ? String(localized: "Your purchases have been restored.")
                    : String(localized: "No active purchases were found for this Apple ID."),
                isRestore: true
            )
        case .failed(let message):
            alertInfo = AlertInfo(
                title: String(localized: "Restore Failed"),
                message: message,
                isRestore: true
            )
        default:
            break
        }
    }

    private func openSubscriptionManagement() {
        #if os(iOS)
        showManageSubscription = true
        #else
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func sectionHeader(title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legalLink(title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Text(title)
                .underline()
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var sheetBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Preview

#Preview {
    ProUpgradeSheet()
}
