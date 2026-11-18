import Foundation

struct EffectMeta {
    let id: String
    let key: String
    let name: String
    let tagline: String
    let duration: Float
    let kind: String
}

/// app/src/lab/registry.js
enum Effects {
    static let impacts: [EffectMeta] = [
        EffectMeta(id: "eclipse", key: "A", name: "Eclipse", tagline: "Razor halo · cyan afterimage", duration: 1.38, kind: "impact"),
        EffectMeta(id: "ember", key: "B", name: "Ember bloom", tagline: "Granular fire · hollow ring", duration: 2.15, kind: "impact"),
        EffectMeta(id: "prism", key: "C", name: "Prism fracture", tagline: "Shard debris · chromatic echo", duration: 1.25, kind: "impact"),
        EffectMeta(id: "resonance", key: "D", name: "Resonance", tagline: "Sonar ripples · radar sweep", duration: 1.8, kind: "impact"),
        EffectMeta(id: "containment", key: "E", name: "Containment", tagline: "360° red shield · subdued", duration: 1.55, kind: "impact"),
    ]

    static let births: [EffectMeta] = [
        EffectMeta(id: "spiral", key: "1", name: "Spiral convergence", tagline: "Orbit · compress · flare", duration: 2.4, kind: "birth"),
        EffectMeta(id: "arc-weld", key: "2", name: "Arc weld", tagline: "Tendrils stitch a core", duration: 2.25, kind: "birth"),
        EffectMeta(id: "seed", key: "3", name: "Seed bloom", tagline: "A seed unfurls the ring", duration: 2.55, kind: "birth"),
        EffectMeta(id: "scan", key: "4", name: "Scan assembly", tagline: "Swept into existence", duration: 2.2, kind: "birth"),
        EffectMeta(id: "redaction", key: "5", name: "Redaction", tagline: "A red line locks the node", duration: 1.95, kind: "birth"),
    ]

    static let deaths: [EffectMeta] = [
        EffectMeta(id: "tectonic", key: "D1", name: "Tectonic rupture", tagline: "Crust cracks · molten plates", duration: 2.95, kind: "death"),
        EffectMeta(id: "collapse", key: "D2", name: "Core collapse", tagline: "Gravity crush · silent shell", duration: 2.7, kind: "death"),
    ]

    static func impact(_ id: String, ctx: EffectContext) -> EffectStudy {
        switch id {
        case "ember": return EmberEffect(ctx: ctx)
        case "prism": return PrismEffect(ctx: ctx)
        case "resonance": return ResonanceEffect(ctx: ctx)
        case "containment": return ContainmentEffect(ctx: ctx)
        default: return EclipseEffect(ctx: ctx)
        }
    }

    static func birth(_ id: String, ctx: EffectContext, node: NodeView) -> EffectStudy {
        switch id {
        case "arc-weld": return ArcWeldEffect(ctx: ctx, node: node)
        case "seed": return SeedBloomEffect(ctx: ctx, node: node)
        case "scan": return ScanEffect(ctx: ctx, node: node)
        case "redaction": return RedactionEffect(ctx: ctx, node: node)
        default: return SpiralEffect(ctx: ctx, node: node)
        }
    }

    static func death(_ id: String, ctx: EffectContext, node: NodeView) -> EffectStudy {
        switch id {
        case "collapse": return CoreCollapseEffect(ctx: ctx, node: node)
        default: return TectonicEffect(ctx: ctx, node: node)
        }
    }

    static func meta(impact id: String) -> EffectMeta {
        impacts.first { $0.id == id } ?? impacts[0]
    }
    static func meta(birth id: String) -> EffectMeta {
        births.first { $0.id == id } ?? births[0]
    }
    static func meta(death id: String) -> EffectMeta {
        deaths.first { $0.id == id } ?? deaths[0]
    }
}
