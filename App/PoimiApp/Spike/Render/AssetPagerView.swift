//
//  AssetPagerView.swift
//  PoimiApp — Spike render layer
//
//  RENDER LAYER — promotable. The full-screen inspection view, reached as a
//  navigation destination via `.navigationTransition(.zoom)` (D10). It is a
//  swipe-between-photos pager that lets you **select in place** (D9/★) so
//  "open to decide" is itself a fast multi-select path, never a dead-end.
//  Progressive full-res via `FullImageLoader`.
//
//  Salvageable tier. Source of assets/selection injected by the caller.

import Photos
import SwiftUI

struct AssetPagerView: View {
    let assets: [PHAsset]
    let isSelected: (PHAsset) -> Bool
    let toggleSelection: (PHAsset) -> Void

    /// The currently-shown asset's localIdentifier. Bound so the parent grid can
    /// restore scroll position to whichever photo the user swiped to (the ★
    /// "which photo we land back on" question).
    @Binding var currentID: String?

    var body: some View {
        TabView(selection: $currentID) {
            ForEach(assets, id: \.localIdentifier) { asset in
                AssetPage(
                    asset: asset,
                    isSelected: isSelected(asset),
                    toggle: { toggleSelection(asset) }
                )
                .tag(Optional(asset.localIdentifier))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))   // swipe left/right
        .ignoresSafeArea(edges: .bottom)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let asset = currentAsset {
                    Button {
                        toggleSelection(asset)
                    } label: {
                        Label(
                            isSelected(asset) ? "Selected" : "Select",
                            systemImage: isSelected(asset) ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        }
    }

    private var currentAsset: PHAsset? {
        guard let currentID else { return assets.first }
        return assets.first { $0.localIdentifier == currentID }
    }
}

/// A single full-screen page: progressive full-res image + an in-place select
/// affordance tappable without leaving the pager.
private struct AssetPage: View {
    let asset: PHAsset
    let isSelected: Bool
    let toggle: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .bottom) {
            Button(action: toggle) {
                Label(
                    isSelected ? "Selected" : "Tap to select",
                    systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                )
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .padding(.bottom, 40)
        }
        // Progressive: degraded → final, cancels on page recycle.
        .task(id: asset.localIdentifier) {
            image = nil
            for await delivered in FullImageLoader.images(for: asset) {
                image = delivered
            }
        }
    }
}
