import Foundation

/// The frame surfaces a host handed over, kept only while the host can still name them. A host
/// draws each tab layer into a small ring of same-sized surfaces and replaces the ring when the
/// layer's size changes, when the tab hides (`hidden` event) and when it closes; this cache drops
/// its references at the same moments, so surfaces stop costing memory once neither side paints
/// them. Surfaces arrive on the transport before the frame that first names them, so an entry may
/// wait without a tab until its frame comes.
struct BrowserFrameSurfaceCache<Surface> {
    struct Entry {
        var surface: Surface
        var tab: BrowserTabID?
        var layer: BrowserFrameLayer?
        var pixelWidth = 0
        var pixelHeight = 0
        var order: UInt64
    }

    /// The host's ring holds at most this many surfaces per layer.
    static var ringCapacity: Int { 4 }
    /// Surfaces received but not yet named by a frame; more than this means frames went missing.
    static var pendingCapacity: Int { 16 }

    private(set) var entries: [UInt64: Entry] = [:]
    private var counter: UInt64 = 0

    var count: Int { entries.count }

    func surface(for token: UInt64) -> Surface? {
        entries[token]?.surface
    }

    /// A surface the transport received; its first frame names its tab and layer.
    mutating func store(_ surface: Surface, token: UInt64) {
        counter += 1
        entries[token] = Entry(surface: surface, order: counter)
        let pending = entries.filter { $0.value.tab == nil }.sorted { $0.value.order < $1.value.order }
        for (token, _) in pending.dropLast(Self.pendingCapacity) { entries.removeValue(forKey: token) }
    }

    /// A frame named `frame.surface`: the surface now belongs to the tab's layer at the frame's
    /// size. Surfaces of that layer at another size belong to a ring the host replaced, and beyond
    /// the ring's capacity the oldest were replaced too; both are dropped.
    mutating func noteFrame(_ frame: BrowserFrame, tab: BrowserTabID) {
        guard var entry = entries[frame.surface] else { return }
        counter += 1
        entry.tab = tab
        entry.layer = frame.layer
        entry.pixelWidth = frame.pixelWidth
        entry.pixelHeight = frame.pixelHeight
        entry.order = counter
        entries[frame.surface] = entry
        let sameLayer = entries.filter { $0.value.tab == tab && $0.value.layer == frame.layer }
        for (token, other) in sameLayer where other.pixelWidth != frame.pixelWidth || other.pixelHeight != frame.pixelHeight {
            entries.removeValue(forKey: token)
        }
        let ring = entries.filter { $0.value.tab == tab && $0.value.layer == frame.layer }
            .sorted { $0.value.order < $1.value.order }
        for (token, _) in ring.dropLast(Self.ringCapacity) { entries.removeValue(forKey: token) }
    }

    /// Drops every surface of the tab (`hidden`, `closed`), or of one of its layers (a popup that
    /// went away).
    mutating func evict(tab: BrowserTabID, layer: BrowserFrameLayer? = nil) {
        entries = entries.filter { $0.value.tab != tab || (layer != nil && $0.value.layer != layer) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
