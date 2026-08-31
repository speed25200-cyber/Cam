import SwiftUI

/// Directional pad + zoom slider driving ONVIF ContinuousMove/Stop.
struct PTZControlView: View {
    let onMove: (PTZVector) -> Void
    let onStop: () -> Void
    let presets: [PTZPreset]
    let onGotoPreset: (PTZPreset) -> Void
    let onSavePreset: () -> Void

    private let step = 0.5

    var body: some View {
        VStack(spacing: 16) {
            Text("Direction (PTZ)").font(.headline)

            VStack(spacing: 8) {
                directionButton("arrow.up", vector: PTZVector(pan: 0, tilt: step, zoom: 0))
                HStack(spacing: 8) {
                    directionButton("arrow.left", vector: PTZVector(pan: -step, tilt: 0, zoom: 0))
                    Button {
                        onStop()
                    } label: {
                        Image(systemName: "stop.fill").font(.title3)
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 52, height: 52)
                    directionButton("arrow.right", vector: PTZVector(pan: step, tilt: 0, zoom: 0))
                }
                directionButton("arrow.down", vector: PTZVector(pan: 0, tilt: -step, zoom: 0))
            }

            HStack(spacing: 24) {
                directionButton("minus.magnifyingglass", vector: PTZVector(pan: 0, tilt: 0, zoom: -step), label: "Zoom -")
                directionButton("plus.magnifyingglass", vector: PTZVector(pan: 0, tilt: 0, zoom: step), label: "Zoom +")
            }

            if !presets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Préréglages").font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(presets) { preset in
                                Button(preset.name) { onGotoPreset(preset) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            Button("Enregistrer la position actuelle", action: onSavePreset)
                .buttonStyle(.bordered)
        }
    }

    private func directionButton(_ systemImage: String, vector: PTZVector, label: String? = nil) -> some View {
        Button {
            // no-op tap target; real control is the press-and-hold gesture below
        } label: {
            Image(systemName: systemImage).font(.title3)
        }
        .buttonStyle(.bordered)
        .frame(width: label == nil ? 52 : nil, height: 52)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onMove(vector) }
                .onEnded { _ in onStop() }
        )
        .overlay(alignment: .bottom) {
            if let label {
                Text(label).font(.caption2).offset(y: 16)
            }
        }
    }
}
