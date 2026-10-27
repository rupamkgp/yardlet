import XCTest
@testable import NativeHarnessClient

/// Yardlet keeps a host's frame surfaces only while the host can still paint into them.
final class BrowserFrameSurfaceCacheTests: XCTestCase {
    private func frame(_ surface: UInt64, layer: BrowserFrameLayer = .view, width: Int = 800, height: Int = 600) -> BrowserFrame {
        BrowserFrame(layer: layer, surface: surface, pixelWidth: width, pixelHeight: height, sequence: surface,
                     paintedAt: 0, source: "accelerated")
    }

    func testARingsSurfacesStayAndAResizedLayersOldSurfacesGo() {
        var cache = BrowserFrameSurfaceCache<String>()
        for id: UInt64 in 1...3 {
            cache.store("s\(id)", token: id)
            cache.noteFrame(frame(id), tab: 1)
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.surface(for: 2), "s2")

        // The panel grew: the host paints into a new ring; the old one is dropped on both sides.
        cache.store("s4", token: 4)
        cache.noteFrame(frame(4, width: 900, height: 700), tab: 1)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.surface(for: 1))
        XCTAssertEqual(cache.surface(for: 4), "s4")
    }

    func testAnotherTabsAndThePopupsSurfacesAreUntouchedByAResize() {
        var cache = BrowserFrameSurfaceCache<String>()
        cache.store("a", token: 1); cache.noteFrame(frame(1), tab: 1)
        cache.store("b", token: 2); cache.noteFrame(frame(2), tab: 2)
        cache.store("p", token: 3); cache.noteFrame(frame(3, layer: .popup, width: 100, height: 50), tab: 1)
        cache.store("c", token: 4); cache.noteFrame(frame(4, width: 10, height: 10), tab: 1)
        XCTAssertEqual(Set(cache.entries.keys), [2, 3, 4])
    }

    func testTheRingCapacityBoundsALayerEvenAtOneSize() {
        var cache = BrowserFrameSurfaceCache<String>()
        for id: UInt64 in 1...6 {
            cache.store("s\(id)", token: id)
            cache.noteFrame(frame(id), tab: 1)
        }
        XCTAssertEqual(Set(cache.entries.keys), [3, 4, 5, 6], "the oldest beyond the host's ring of four go")
    }

    func testHidingOrClosingATabDropsAllItsSurfacesAndAClosedPopupItsLayer() {
        var cache = BrowserFrameSurfaceCache<String>()
        cache.store("a", token: 1); cache.noteFrame(frame(1), tab: 1)
        cache.store("p", token: 2); cache.noteFrame(frame(2, layer: .popup, width: 100, height: 50), tab: 1)
        cache.store("b", token: 3); cache.noteFrame(frame(3), tab: 2)
        cache.evict(tab: 1, layer: .popup)
        XCTAssertEqual(Set(cache.entries.keys), [1, 3])
        cache.evict(tab: 1)
        XCTAssertEqual(Set(cache.entries.keys), [3])
    }

    func testSurfacesReceivedBeforeTheirFrameWaitButNotWithoutBound() {
        var cache = BrowserFrameSurfaceCache<String>()
        cache.store("early", token: 1)
        XCTAssertEqual(cache.surface(for: 1), "early", "the port delivers a surface before the frame that names it")
        for id: UInt64 in 2...40 { cache.store("s\(id)", token: id) }
        XCTAssertNil(cache.surface(for: 1), "surfaces no frame ever named are not kept forever")
        XCTAssertEqual(cache.count, BrowserFrameSurfaceCache<String>.pendingCapacity)
        cache.noteFrame(frame(40), tab: 1)
        XCTAssertEqual(cache.surface(for: 40), "s40")
    }
}
