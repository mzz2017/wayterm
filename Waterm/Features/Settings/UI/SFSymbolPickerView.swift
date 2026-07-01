//
//  SFSymbolPickerView.swift
//  Waterm
//
//  SF Symbol picker with full system symbols from CoreGlyphs bundle
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Cross-platform color helpers
private extension Color {
    static var systemBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var controlBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }
}

// MARK: - SFSymbolPickerView

struct SFSymbolPickerView: View {
    @Binding var selectedSymbol: String
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var displayLimit = 200
    @ObservedObject private var recentManager: RecentSymbolsManager

    private let provider: SFSymbolsProvider
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private let pageSize = 200

    init(
        selectedSymbol: Binding<String>,
        isPresented: Binding<Bool>,
        provider: SFSymbolsProvider,
        recentManager: RecentSymbolsManager
    ) {
        _selectedSymbol = selectedSymbol
        _isPresented = isPresented
        self.provider = provider
        _recentManager = ObservedObject(wrappedValue: recentManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            categoryTabsView
            Divider()
            symbolGridView
        }
        .frame(width: 540, height: 480)
        .background(Color.systemBackground)
        .onChange(of: searchText) { _ in
            displayLimit = pageSize
        }
        .onChange(of: selectedCategory) { _ in
            displayLimit = pageSize
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search symbols...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.controlBackground)
            .cornerRadius(8)

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }

    // MARK: - Category Tabs

    private var categoryTabsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !recentManager.recentSymbols.isEmpty && searchText.isEmpty {
                    categoryTab(key: "recent", icon: "clock", name: String(localized: "Recent"))
                }

                ForEach(provider.categories, id: \.key) { category in
                    categoryTab(key: category.key, icon: category.icon, name: category.name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.controlBackground.opacity(0.5))
    }

    private func categoryTab(key: String, icon: String, name: String) -> some View {
        Button {
            selectedCategory = key
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(name)
                    .font(.system(size: 11, weight: selectedCategory == key ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selectedCategory == key ?
                Color.accentColor.opacity(0.15) :
                Color.clear
            )
            .foregroundColor(selectedCategory == key ? .accentColor : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Symbol Grid

    private var allFilteredSymbols: [String] {
        if !searchText.isEmpty {
            return provider.search(searchText)
        }
        if selectedCategory == "recent" {
            return recentManager.recentSymbols
        }
        return provider.symbols(for: selectedCategory)
    }

    private var displayedSymbols: [String] {
        Array(allFilteredSymbols.prefix(displayLimit))
    }

    private var hasMore: Bool {
        allFilteredSymbols.count > displayLimit
    }

    private var symbolGridView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Count label
                HStack {
                    Text(String(format: String(localized: "%lld symbols"), Int64(allFilteredSymbols.count)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Grid
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(displayedSymbols, id: \.self) { symbol in
                        symbolButton(symbol)
                    }
                }
                .padding(.horizontal, 12)

                // Load more button
                if hasMore {
                    Button {
                        displayLimit += pageSize
                    } label: {
                        Text(String(format: String(localized: "Load more (%lld remaining)"), Int64(allFilteredSymbols.count - displayLimit)))
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color.controlBackground)
    }

    private func symbolButton(_ symbol: String) -> some View {
        Button {
            selectedSymbol = symbol
            recentManager.addRecent(symbol)
            isPresented = false
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 56, height: 56)
                .foregroundColor(selectedSymbol == symbol ? .white : .primary)
                .background(
                    selectedSymbol == symbol ?
                    Color.accentColor :
                    Color.systemBackground
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}
