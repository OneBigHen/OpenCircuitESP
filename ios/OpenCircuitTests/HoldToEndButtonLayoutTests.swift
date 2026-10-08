import SwiftUI
import XCTest
@testable import OpenCircuit

/// The End button once contained a greedy GeometryReader and, given a tall container (the workout
/// screen's VStack), grew far taller than the Pause button beside it. Pin that it stays button-sized
/// even when the parent offers plenty of vertical room.
@MainActor
final class HoldToEndButtonLayoutTests: XCTestCase {
    private final class Box { var height: CGFloat = .infinity }

    func testEndButtonStaysButtonSizedInATallContainer() {
        let box = Box()
        let content = VStack(spacing: 0) {
            HoldToEndButton(title: "End") { }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { box.height = $0 }
            Color.clear.frame(height: 10)
        }
        .frame(width: 390, height: 700, alignment: .top)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        _ = renderer.uiImage
        XCTAssertLessThan(box.height, 80, "the End button must stay button-sized (was \(box.height)pt)")
        XCTAssertGreaterThanOrEqual(box.height, 44)
    }
}
