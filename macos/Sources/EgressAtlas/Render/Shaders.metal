#include <metal_stdlib>
using namespace metal;

// Ports of the GLSL in app/src/lab and the Three.js post-processing passes.
// The scene is rendered into a linear HDR target and tone mapped only in the
// final composite, exactly like the web's EffectComposer + OutputPass chain.

constant float PI = 3.14159265358979323846;
constant float TAU = 6.28318530717958647692;

struct FrameUniforms {
    float4x4 viewProj;
    float4x4 view;
    float4 cameraPos;      // xyz
    float4 viewport;       // width, height, 1/width, 1/height
    float4 cameraRight;
    float4 cameraUp;
    float4 cameraForward;
    float4 misc;           // time, pointScale, aspect, tanHalfFov
    float4 stage;          // stageScale, backdropYaw, near, far
};

struct LineUniforms {
    float4x4 transform;
};

struct LineVertex {
    float4 position;
    float4 color;
};

struct PointVertex {
    float4 position;
    float4 color;
    float4 params; // size
};

struct ShapeVertex {
    float4 position;
    float4 normal;
    float2 uv;
    float2 pad;
};

struct MeshInstance {
    float4x4 model;
    float4 color;
};

struct SpriteInstance {
    float4 center; // xyz, mode
    float4 size;   // width, height, rotation, opacity
    float4 color;  // rgb
    float4 extra;
};

struct NodeRingUniforms {
    float4 centerHalf;
    float4 params; // radius, phase, opacity, hover
    float4 gold;
    float4 hot;
    float4 signal;
};

struct ShockUniforms {
    float4 center;
    float4 basisT;
    float4 basisB;
    float4 meta0; // t, start, end, half
    float4 meta1; // thickness, rays, seed, opacity
    float4 meta2; // inner, hot, 0, 0
    float4 core;
    float4 tail;
};

struct AtmoUniforms {
    float4x4 model;
    float4 warm;    // rgb, strength
    float4 cool;    // rgb, time
    float4 params;  // mode
};

struct PlanetUniforms {
    float4x4 model;
    float4 rockA;
    float4 rockB;
    float4 accent;
    float4 hot;
};

struct PlanetAtmoUniforms {
    float4x4 model;
    float4 color; // rgb, opacity
};

struct ShockShellUniforms {
    float4x4 model;
    float4 color;
    float4 accent;
    float4 params; // opacity, time
};

struct ShieldUniforms {
    float4x4 model;
    float4 shell;
    float4 rim;
    float4 hot;
    float4 hitDir;
    float4 params; // opacity, time, ripple, contact
};

struct ScanUniforms {
    float4x4 model;
    float4 color;
    float4 params; // radius, half, opacity, angle
};

struct DiscUniforms {
    float4x4 model;
    float4 color;
    float4 hot;
    float4 params; // opacity, time
};

struct JetUniforms {
    float4x4 model;
    float4 core;
    float4 edge;
    float4 params; // opacity, time
};

struct DofUniforms {
    float4 params;       // focus, aperture, maxblur, aspect
    float4 cameraPos;
    float4 cameraRight;
    float4 cameraUp;
    float4 cameraForward;
    float4 depthParams;  // tanHalfFov, globeRadius, near, far
};

struct BrightUniforms {
    float4 params; // threshold, smoothWidth, exposure, 0
};

struct BlurUniforms {
    float4 offsets[3];
    float4 weights[3];
    float4 directionSize; // dirx, diry, invW, invH
    float4 params;        // pairCount, centerWeight, 0, 0
};

struct BloomUniforms {
    float4 params; // strength, radius, 0, 0
};

struct FinalUniforms {
    float4 params;     // elapsed, bloomEnabled, logicalW, logicalH
    float4 renderSize; // w, h, 1/w, 1/h
};

// ── helpers ───────────────────────────────────────────────────────────────

static inline float3 srgbToLinear3(float3 c) {
    float3 l = c * 0.0773993808;
    float3 h = pow(c * 0.9478672986 + 0.0521327014, float3(2.4));
    return select(l, h, c > float3(0.04045));
}

static inline float easeOutQuint(float t) {
    return 1.0 - pow(1.0 - t, 5.0);
}

static inline float3 acesFilm(float3 color, float exposure) {
    color *= exposure / 0.6;
    // ACESInputMat from three.js tonemapping_pars_fragment (column-major).
    float3 a;
    a.r = 0.59719 * color.r + 0.35458 * color.g + 0.04823 * color.b;
    a.g = 0.07600 * color.r + 0.90834 * color.g + 0.01566 * color.b;
    a.b = 0.02840 * color.r + 0.13383 * color.g + 0.83777 * color.b;
    float3 v = a;
    float3 fit = (v * (v + 0.0245786) - 0.000090537) /
                 (v * (0.983729 * v + 0.4329510) + 0.238081);
    color = fit;
    float3 o;
    o.r = 1.60475 * color.r - 0.53108 * color.g - 0.07367 * color.b;
    o.g = -0.10208 * color.r + 1.10813 * color.g - 0.00605 * color.b;
    o.b = -0.00327 * color.r - 0.07276 * color.g + 1.07602 * color.b;
    return saturate(o);
}

static inline float3 linearToSRGB(float3 c) {
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
    return select(lo, hi, c > float3(0.0031308));
}

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// The procedural sprite maps from textures.js, evaluated analytically.
static inline float glowAlpha(float r) {
    float a = mix(0.95, 0.80, smoothstep(0.0, 0.09, r));
    a = mix(a, 0.32, smoothstep(0.09, 0.25, r));
    a = mix(a, 0.08, smoothstep(0.25, 0.52, r));
    a = mix(a, 0.018, smoothstep(0.52, 0.78, r));
    a = mix(a, 0.0, smoothstep(0.78, 1.0, r));
    return a;
}

static inline float sparkAlpha(float r) {
    float a = mix(1.0, 0.98, smoothstep(0.0, 0.16, r));
    a = mix(a, 0.50, smoothstep(0.16, 0.38, r));
    a = mix(a, 0.09, smoothstep(0.38, 0.70, r));
    a = mix(a, 0.0, smoothstep(0.70, 1.0, r));
    return a;
}

// ── background star sphere (GlobeStage.starFragment) ─────────────────────

struct BackgroundOut {
    float4 position [[position]];
    float2 uv;
};

vertex BackgroundOut background_vertex(uint vid [[vertex_id]],
                                       constant FrameUniforms &frame [[buffer(0)]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = positions[vid];
    BackgroundOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * float2(0.5, -0.5) + 0.5;
    return out;
}

fragment float4 background_fragment(BackgroundOut in [[stage_in]],
                                    constant FrameUniforms &frame [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float3 ray = normalize(frame.cameraForward.xyz
                           + frame.cameraRight.xyz * (ndc.x * frame.misc.w * frame.misc.z)
                           + frame.cameraUp.xyz * (ndc.y * frame.misc.w));
    // The backdrop is a real sphere seen from inside; its shader keys off the
    // direction from the sphere centre, not the camera ray. Scale it with the
    // globe so a large computed globe still renders from within the sky.
    float backdropRadius = 82.0 * max(1.0, frame.stage.x);
    float3 ro = frame.cameraPos.xyz;
    float b = dot(ro, ray);
    float c = dot(ro, ro) - backdropRadius * backdropRadius;
    float disc = b * b - c;
    float t = -b + sqrt(max(0.0, disc));
    float3 hit = ro + ray * t;
    // The backdrop sphere rotates slowly around Y.
    float yaw = -frame.stage.y;
    float cy = cos(yaw);
    float sy = sin(yaw);
    hit = float3(cy * hit.x + sy * hit.z, hit.y, -sy * hit.x + cy * hit.z);
    float3 d = normalize(hit);
    float h = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);
    float3 col = mix(float3(0.012, 0.0055, 0.0028),
                     float3(0.0022, 0.001, 0.0006),
                     smoothstep(0.3, 0.94, h));
    float front = max(0.0, -d.z);
    float band = exp(-pow((d.y - 0.06) * 3.2, 2.0));
    col += float3(0.05, 0.022, 0.009) * band * pow(front, 2.6) * 0.13;
    float cool = exp(-pow((d.x - 0.45) * 2.6, 2.0)) * exp(-pow((d.y + 0.16) * 3.6, 2.0));
    col += float3(0.007, 0.018, 0.024) * cool * 0.14;
    float n = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * 0.0016;
    return float4(col, 1.0);
}

// ── lines ────────────────────────────────────────────────────────────────

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut line_vertex(constant LineVertex *verts [[buffer(0)]],
                           constant LineUniforms &uniforms [[buffer(1)]],
                           constant FrameUniforms &frame [[buffer(2)]],
                           uint vid [[vertex_id]]) {
    LineVertex v = verts[vid];
    LineOut out;
    out.position = frame.viewProj * (uniforms.transform * float4(v.position.xyz, 1.0));
    out.color = v.color;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    return in.color;
}

// ── point clouds (SparkCloud) ────────────────────────────────────────────

struct PointOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

vertex PointOut point_vertex(constant PointVertex *verts [[buffer(0)]],
                             constant LineUniforms &uniforms [[buffer(1)]],
                             constant FrameUniforms &frame [[buffer(2)]],
                             uint vid [[vertex_id]]) {
    PointVertex v = verts[vid];
    float4 world = uniforms.transform * float4(v.position.xyz, 1.0);
    float4 view = frame.view * world;
    float depth = max(0.15, -view.z);
    PointOut out;
    out.color = v.color;
    out.pointSize = clamp(v.params.x * 2.0 * frame.misc.y / depth, 0.0, 96.0);
    out.position = frame.viewProj * world;
    return out;
}

fragment float4 point_fragment(PointOut in [[stage_in]],
                               float2 pc [[point_coord]]) {
    float r = length(pc * 2.0 - 1.0);
    float a = sparkAlpha(r) * in.color.a * 1.5;
    if (a < 0.002) discard_fragment();
    return float4(in.color.rgb * 1.7, a);
}

// ── camera-facing sprites (glow / streak / limb) ─────────────────────────

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float mode;
    float opacity;
};

vertex SpriteOut sprite_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               constant SpriteInstance *instances [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]]) {
    SpriteInstance inst = instances[iid];
    float2 corners[6] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5),
                          float2(-0.5, 0.5), float2(0.5, -0.5), float2(0.5, 0.5) };
    float2 c = corners[vid];
    float3 center = inst.center.xyz;
    float3 world = center + frame.cameraRight.xyz * (c.x * inst.size.x)
                          + frame.cameraUp.xyz * (c.y * inst.size.y);
    SpriteOut out;
    out.position = frame.viewProj * float4(world, 1.0);
    out.uv = float2(c.x + 0.5, 0.5 - c.y);
    out.color = inst.color;
    out.mode = inst.center.w;
    out.opacity = inst.size.w;
    return out;
}

fragment float4 sprite_fragment(SpriteOut in [[stage_in]]) {
    float2 p = in.uv * 2.0 - 1.0;
    p.y = -p.y;
    float r = length(p);
    float alpha = 0.0;
    float3 col = in.color.rgb;

    if (in.mode < 0.5) {
        // glowTexture
        alpha = glowAlpha(r);
    } else if (in.mode < 1.5) {
        // sparkTexture
        alpha = sparkAlpha(r);
        col *= 1.7;
    } else if (in.mode < 2.5) {
        // streakTexture
        alpha = exp(-abs(p.x) * 1.8) * exp(-abs(p.y) * 46.0);
    } else {
        // Limb texture: a soft coral ring and a razor gold ring. The sprite
        // material tint is gold in GlobeStage.
        float ring1 = 0.0;
        float ring2 = 0.0;
        {
            float t = clamp((r - (500.0 - 26.0) / 512.0) / (52.0 / 512.0), 0.0, 1.0);
            float a = 0.0;
            a = mix(0.0, 0.0, smoothstep(0.0, 0.46, t));
            a = mix(a, 0.9, smoothstep(0.46, 0.5, t));
            a = mix(a, 0.18, smoothstep(0.5, 0.54, t));
            a = mix(a, 0.0, smoothstep(0.54, 1.0, t));
            ring1 = a;
        }
        {
            float t = clamp((r - (508.0 - 4.0) / 512.0) / (8.0 / 512.0), 0.0, 1.0);
            float a = 0.0;
            a = mix(0.0, 0.0, smoothstep(0.0, 0.46, t));
            a = mix(a, 0.9, smoothstep(0.46, 0.5, t));
            a = mix(a, 0.18, smoothstep(0.5, 0.54, t));
            a = mix(a, 0.0, smoothstep(0.54, 1.0, t));
            ring2 = a;
        }
        float3 coral = float3(0.878431, 0.501961, 0.407843);
        float3 gold = float3(0.972549, 0.776471, 0.356863);
        float3 tint = in.color.rgb;
        float total = ring1 + ring2;
        col = (coral * ring1 + gold * ring2) * tint;
        alpha = total;
    }
    alpha *= in.opacity;
    if (alpha < 0.002) discard_fragment();
    return float4(col, alpha);
}

// ── instanced unlit meshes ───────────────────────────────────────────────

struct MeshOut {
    float4 position [[position]];
    float4 color;
};

vertex MeshOut mesh_vertex(constant ShapeVertex *verts [[buffer(2)]],
                           constant MeshInstance *instances [[buffer(0)]],
                           constant FrameUniforms &frame [[buffer(1)]],
                           uint vid [[vertex_id]],
                           uint iid [[instance_id]]) {
    ShapeVertex v = verts[vid];
    MeshInstance inst = instances[iid];
    float4 world = inst.model * float4(v.position.xyz, 1.0);
    MeshOut out;
    out.position = frame.viewProj * world;
    out.color = inst.color;
    return out;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]]) {
    return in.color;
}

// ── destination instrument ring (NodeView.nodeRingFragment) ───────────────

struct NodeRingOut {
    float4 position [[position]];
    float2 p;
};

vertex NodeRingOut node_ring_vertex(uint vid [[vertex_id]],
                                    constant NodeRingUniforms &u [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]]) {
    float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                          float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];
    float3 world = u.centerHalf.xyz
                 + frame.cameraRight.xyz * (c.x * u.centerHalf.w)
                 + frame.cameraUp.xyz * (c.y * u.centerHalf.w);
    NodeRingOut out;
    out.position = frame.viewProj * float4(world, 1.0);
    out.p = c;
    return out;
}

fragment float4 node_ring_fragment(NodeRingOut in [[stage_in]],
                                   constant NodeRingUniforms &u [[buffer(0)]],
                                   constant FrameUniforms &frame [[buffer(1)]]) {
    float2 p = in.p;
    float r = length(p) * u.centerHalf.w;
    float radius = u.params.x;
    float phase = u.params.y;
    float opacity = u.params.z;
    float hover = u.params.w;
    float t = frame.misc.x;
    float feather = max(0.006, radius * 0.042);

    float edge = exp(-pow((r - radius) / feather, 2.0));
    float shoulder = exp(-pow((r - radius) / (radius * 0.26), 2.0)) * 0.14;
    float hollow = (1.0 - smoothstep(radius * 0.08, radius * 0.9, r)) * 0.045;

    float ang = atan2(p.y, p.x);
    float ticks = smoothstep(0.84, 1.0, cos(ang * 30.0 + phase))
                * exp(-pow((r - radius * 1.16) / (radius * 0.028), 2.0)) * 0.26;

    float satAng = t * 0.42 + 2.0 + phase;
    float sat = smoothstep(0.93, 1.0, cos(ang - satAng))
              * exp(-pow((r - radius * 1.2) / (radius * 0.095), 2.0));

    float hoverRing = hover * exp(-pow((r - radius * 1.22) / (radius * 0.17), 2.0)) * 0.55;

    float alpha = (edge + shoulder + hollow + ticks + sat * 0.9 + hoverRing) * opacity;
    if (alpha < 0.002) discard_fragment();

    float3 col = mix(u.gold.rgb, u.hot.rgb, clamp(edge * 0.42 + sat, 0.0, 1.0));
    col = mix(col, u.signal.rgb, clamp(hoverRing * 0.9 + sat * 0.55, 0.0, 1.0));
    return float4(col * (0.78 + edge * 0.8 + sat * 1.4), clamp(alpha, 0.0, 1.0));
}

// ── shock rings (effects/shared.js) ──────────────────────────────────────

struct ShockOut {
    float4 position [[position]];
    float2 p;
};

vertex ShockOut shock_vertex(uint vid [[vertex_id]],
                             constant ShockUniforms &u [[buffer(0)]],
                             constant FrameUniforms &frame [[buffer(1)]]) {
    float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                          float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];
    float halfSize = u.meta0.w;
    float3 world = u.center.xyz + u.basisT.xyz * (c.x * halfSize) + u.basisB.xyz * (c.y * halfSize);
    ShockOut out;
    out.position = frame.viewProj * float4(world, 1.0);
    out.p = c;
    return out;
}

fragment float4 shock_fragment(ShockOut in [[stage_in]],
                               constant ShockUniforms &u [[buffer(0)]]) {
    float t = clamp(u.meta0.x, 0.0, 1.0);
    float2 p = in.p;
    float r = length(p) * u.meta0.w;
    float e = easeOutQuint(t);
    float R = mix(u.meta0.y, u.meta0.z, e);
    float fade = pow(1.0 - t, 1.25);
    float w = max(0.0015, u.meta1.x * mix(1.0, 0.32, e));
    float d = abs(r - R);

    float ring = exp(-pow(d / w, 2.0));
    float wakeR = mix(u.meta0.y * 0.72, u.meta0.z * 0.84, e);
    float wake = exp(-pow((r - wakeR) / (w * 2.6), 2.0)) * 0.32;
    float halo = exp(-pow(d / (w * 6.0), 2.0)) * 0.22;

    float ang = atan2(p.y, p.x);
    float rays = 0.0;
    if (u.meta1.y > 0.5) {
        float streak = pow(max(0.0, cos(ang * u.meta1.y + u.meta1.z)), 34.0);
        rays = streak * exp(-pow(d / (w * 4.2), 2.0)) * 0.7;
    }

    float inner = 0.0;
    if (u.meta2.x > 0.5) {
        inner = (1.0 - smoothstep(R * 0.05, R, r)) * 0.07 * (1.0 - t);
    }

    float alpha = (ring + wake + halo + rays + inner) * fade * u.meta1.w;
    if (alpha < 0.002) discard_fragment();

    float3 col = mix(u.tail.rgb, u.core.rgb,
                     clamp(ring * 1.25 + rays * 0.8 + u.meta2.y, 0.0, 1.0));
    return float4(col * (0.82 + ring * 1.15 + rays * 0.35), clamp(alpha, 0.0, 1.0));
}

// ── atmosphere / glass ───────────────────────────────────────────────────

struct AtmoOut {
    float4 position [[position]];
    float3 normalView;
    float3 viewDir;
    float3 worldDir;
};

vertex AtmoOut atmosphere_vertex(constant ShapeVertex *verts [[buffer(2)]],
                                 constant AtmoUniforms &u [[buffer(0)]],
                                 constant FrameUniforms &frame [[buffer(1)]],
                                 uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    AtmoOut out;
    out.position = frame.viewProj * world;
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    out.worldDir = normalize(v.position.xyz);
    return out;
}

fragment float4 atmosphere_fragment(AtmoOut in [[stage_in]],
                                    constant AtmoUniforms &u [[buffer(0)]]) {
    float rim = pow(1.0 - abs(dot(normalize(in.normalView), normalize(in.viewDir))), 2.5);
    float upper = smoothstep(-0.65, 0.9, in.worldDir.y);
    float drift = 0.9 + 0.1 * sin(u.cool.w * 0.18 + in.worldDir.x * 1.6 + in.worldDir.z * 1.1);
    float3 col = mix(u.warm.rgb, u.cool.rgb, smoothstep(0.15, 0.82, upper) * 0.32);
    float a = (rim * 0.36 + 0.015) * u.warm.w * drift;
    return float4(col * (0.72 + rim * 1.4), clamp(a, 0.0, 1.0));
}

fragment float4 glass_fragment(AtmoOut in [[stage_in]],
                               constant AtmoUniforms &u [[buffer(0)]]) {
    float rim = pow(1.0 - abs(dot(normalize(in.normalView), normalize(in.viewDir))), 3.2);
    float scan = smoothstep(0.985, 1.0, sin(in.worldDir.y * 42.0 + u.cool.w * 0.16)) * 0.018;
    float3 col = mix(u.warm.rgb, float3(1.0, 0.92, 0.78), rim * 0.55);
    float a = rim * 0.012 + scan * 0.5 + 0.0015;
    return float4(col, clamp(a, 0.0, 1.0));
}

// ── planet (death/planet.js) ─────────────────────────────────────────────

struct PlanetOut {
    float4 position [[position]];
    float3 local;
    float3 normalView;
    float3 viewDir;
};

vertex PlanetOut planet_vertex(constant ShapeVertex *verts [[buffer(2)]],
                               constant PlanetUniforms &u [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    PlanetOut out;
    out.position = frame.viewProj * world;
    out.local = normalize(v.position.xyz);
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    return out;
}

static inline float pnoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float h000 = hash12(i.xy + i.z * 19.19);
    float h100 = hash12((i + float3(1, 0, 0)).xy + i.z * 19.19);
    float h010 = hash12((i + float3(0, 1, 0)).xy + i.z * 19.19);
    float h110 = hash12((i + float3(1, 1, 0)).xy + i.z * 19.19);
    float h001 = hash12(i.xy + (i.z + 1.0) * 19.19);
    float h101 = hash12((i + float3(1, 0, 0)).xy + (i.z + 1.0) * 19.19);
    float h011 = hash12((i + float3(0, 1, 0)).xy + (i.z + 1.0) * 19.19);
    float h111 = hash12((i + float3(1, 1, 0)).xy + (i.z + 1.0) * 19.19);
    return mix(mix(mix(h000, h100, f.x), mix(h010, h110, f.x), f.y),
               mix(mix(h001, h101, f.x), mix(h011, h111, f.x), f.y), f.z);
}

fragment float4 planet_fragment(PlanetOut in [[stage_in]],
                                constant PlanetUniforms &u [[buffer(0)]]) {
    float3 p = normalize(in.local);
    float3 n = normalize(in.normalView);
    float3 v = normalize(in.viewDir);
    float grain = pnoise(p * 4.1) * 0.62 + pnoise(p * 12.0) * 0.3;
    float3 rock = mix(u.rockB.rgb, u.rockA.rgb, smoothstep(0.22, 0.82, grain));
    float bands = 0.5 + 0.5 * sin(p.y * 19.0 + grain * 8.0);
    rock *= 0.72 + bands * 0.32;

    float light = clamp(dot(n, normalize(float3(-0.48, 0.58, 0.72))), 0.0, 1.0);
    rock *= 0.12 + 0.95 * light;
    float fres = pow(1.0 - max(dot(n, v), 0.0), 2.35);

    float lon = atan2(p.z, p.x);
    float lat = asin(clamp(p.y, -1.0, 1.0));
    float seamA = smoothstep(0.975, 1.0, cos(lon * 9.0 + sin(lat * 5.0) * 1.7));
    float seamB = smoothstep(0.985, 1.0, cos(lat * 14.0 + sin(lon * 8.0) * 1.3));
    float seam = clamp(max(seamA, seamB), 0.0, 1.0);
    float hot = u.rockB.w * (0.28 + seam * 2.2) + u.accent.w * seam * 1.8;

    float3 col = rock;
    col += u.accent.rgb * fres * (0.22 + u.rockB.w * 0.42);
    col += u.accent.rgb * seam * u.accent.w * 0.8;
    col += u.hot.rgb * hot * (0.75 + fres * 0.8);
    col += u.accent.rgb * fres * 0.08;
    return float4(col, u.rockA.w);
}

fragment float4 planet_atmo_fragment(PlanetOut in [[stage_in]],
                                     constant PlanetAtmoUniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.normalView);
    float3 v = normalize(in.viewDir);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 2.2);
    float alpha = rim * u.color.w;
    if (alpha < 0.002) discard_fragment();
    return float4(u.color.rgb * (0.9 + rim * 1.4), alpha);
}

vertex PlanetOut planet_atmo_vertex(constant ShapeVertex *verts [[buffer(2)]],
                                    constant PlanetAtmoUniforms &u [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]],
                                    uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    PlanetOut out;
    out.position = frame.viewProj * world;
    out.local = normalize(v.position.xyz);
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    return out;
}

// ── shock shell ──────────────────────────────────────────────────────────

fragment float4 shock_shell_fragment(PlanetOut in [[stage_in]],
                                      constant ShockShellUniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.normalView);
    float3 v = normalize(in.viewDir);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.4);
    float ribbons = sin(atan2(n.z, n.x) * 17.0 + atan2(n.y, length(n.xz)) * 11.0 - u.params.y * 4.0) * 0.5 + 0.5;
    ribbons = smoothstep(0.55, 0.98, ribbons);
    float alpha = rim * (0.82 + ribbons * 0.42) * u.params.x;
    if (alpha < 0.002) discard_fragment();
    return float4(mix(u.color.rgb, u.accent.rgb, rim * 0.55), alpha);
}

vertex PlanetOut shock_shell_vertex(constant ShapeVertex *verts [[buffer(2)]],
                                    constant ShockShellUniforms &u [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]],
                                    uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    PlanetOut out;
    out.position = frame.viewProj * world;
    out.local = normalize(v.position.xyz);
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    return out;
}

// ── containment shield ───────────────────────────────────────────────────

struct ShieldOut {
    float4 position [[position]];
    float3 dirLocal;
    float3 normalView;
    float3 viewDir;
};

vertex ShieldOut shield_vertex(constant ShapeVertex *verts [[buffer(2)]],
                               constant ShieldUniforms &u [[buffer(0)]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    ShieldOut out;
    out.position = frame.viewProj * world;
    out.dirLocal = normalize(v.position.xyz);
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    return out;
}

fragment float4 shield_fragment(ShieldOut in [[stage_in]],
                                constant ShieldUniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.dirLocal);
    float3 hit = normalize(u.hitDir.xyz);
    float cosA = clamp(dot(n, hit), -1.0, 1.0);
    float theta = acos(cosA);

    float fres = pow(1.0 - abs(dot(normalize(in.normalView), normalize(in.viewDir))), 2.1);
    float lon = atan2(n.z, n.x);
    float lat = asin(clamp(n.y, -1.0, 1.0));
    float lattice = smoothstep(0.955, 1.0, abs(sin(lon * 9.0)) * abs(sin(lat * 7.0)));
    lattice *= 0.05;

    float rippleT = u.params.z;
    float wave = rippleT * 3.06;
    float width = 0.15 + rippleT * 0.18;
    float ripple = exp(-pow((theta - wave) / width, 2.0)) * (1.0 - rippleT);
    float echo = exp(-pow((theta - wave * 0.63) / (width * 1.9), 2.0)) * (1.0 - rippleT) * 0.3;
    float contact = exp(-pow(theta / (0.22 + rippleT * 0.45), 2.0)) * u.params.w;

    float alpha = (fres * 0.34 + lattice * 0.7 + ripple * 0.52 + echo * 0.8 + contact * 0.42) * u.params.x;
    if (alpha < 0.002) discard_fragment();

    float3 col = mix(u.shell.rgb, u.rim.rgb, clamp(fres * 0.6 + lattice * 2.0, 0.0, 1.0));
    col = mix(col, u.hot.rgb, clamp(ripple + contact, 0.0, 1.0));
    return float4(col * (0.82 + fres * 0.55 + ripple * 0.9 + contact * 1.2), clamp(alpha, 0.0, 1.0));

}

// ── scan assembly plane ──────────────────────────────────────────────────

struct ScanOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScanOut scan_vertex(uint vid [[vertex_id]],
                           constant ScanUniforms &u [[buffer(0)]],
                           constant FrameUniforms &frame [[buffer(1)]]) {
    float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                          float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];
    // Horizontal plane: local XY of the web plane becomes XZ.
    float4 local = float4(c.x, 0.0, c.y, 1.0);
    ScanOut out;
    out.position = frame.viewProj * (u.model * local);
    out.uv = c * 0.5 + 0.5;
    return out;
}

fragment float4 scan_fragment(ScanOut in [[stage_in]],
                              constant ScanUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float r = length(p) * u.params.y;
    float radius = u.params.x;
    float opacity = u.params.z;
    float angle = u.params.w;
    float ring = exp(-pow((r - radius) / (radius * 0.022), 2.0));
    float inner = exp(-pow(r / (radius * 0.92), 2.0)) * 0.055;
    float ang = atan2(p.y, p.x);
    float sweep = smoothstep(0.965, 1.0, cos(ang - angle))
                * exp(-pow((r - radius * 0.55) / (radius * 0.55), 2.0)) * 0.09;
    float alpha = (ring + inner + sweep) * opacity;
    if (alpha < 0.002) discard_fragment();
    return float4(u.color.rgb * (1.0 + ring * 2.4), clamp(alpha, 0.0, 1.0));
}

// ── orbital shear disc ───────────────────────────────────────────────────

struct DiscOut {
    float4 position [[position]];
    float2 uv;
};

vertex DiscOut disc_vertex(uint vid [[vertex_id]],
                           constant DiscUniforms &u [[buffer(0)]],
                           constant FrameUniforms &frame [[buffer(1)]]) {
    float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
                          float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0) };
    float2 c = corners[vid];
    float4 local = float4(c.x, 0.0, c.y, 1.0);
    DiscOut out;
    out.position = frame.viewProj * (u.model * local);
    out.uv = c * 0.5 + 0.5;
    return out;
}

fragment float4 disc_fragment(DiscOut in [[stage_in]],
                              constant DiscUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float r = length(p);
    if (r > 1.0) discard_fragment();
    float a = atan2(p.y, p.x);
    float time = u.params.y;
    float streak = smoothstep(0.45, 1.0, cos(a * 34.0 + time * 2.6));
    float grain = hash12(float2(floor(a * 28.0), floor(r * 14.0 + time * 2.0)));
    float bands = 0.35 + 0.65 * (0.5 + 0.5 * sin(r * 36.0 - time * 3.8));
    float edge = smoothstep(0.14, 0.92, r) * (1.0 - smoothstep(0.78, 1.0, r));
    float alpha = (edge * 0.22 + streak * edge * 0.48 + grain * edge * 0.12) * bands * u.params.x;
    if (alpha < 0.002) discard_fragment();
    float3 col = mix(u.color.rgb, u.hot.rgb, clamp(streak * 0.7 + r * 0.2, 0.0, 1.0));
    return float4(col, clamp(alpha, 0.0, 1.0));
}

// ── vapor jet ────────────────────────────────────────────────────────────

struct JetOut {
    float4 position [[position]];
    float2 uv;
    float3 normalView;
    float3 viewDir;
};

vertex JetOut jet_vertex(constant ShapeVertex *verts [[buffer(2)]],
                         constant JetUniforms &u [[buffer(0)]],
                         constant FrameUniforms &frame [[buffer(1)]],
                         uint vid [[vertex_id]]) {
    ShapeVertex v = verts[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    float4 mv = frame.view * world;
    JetOut out;
    out.position = frame.viewProj * world;
    out.uv = v.uv;
    out.normalView = normalize((frame.view * (u.model * float4(v.normal.xyz, 0.0))).xyz);
    out.viewDir = normalize(-mv.xyz);
    return out;
}

fragment float4 jet_fragment(JetOut in [[stage_in]],
                             constant JetUniforms &u [[buffer(0)]]) {
    float y = in.uv.y;
    float a = in.uv.x * TAU;
    float filament = 0.5 + 0.5 * sin(a * 13.0 + y * 21.0 - u.params.y * 5.0);
    filament = smoothstep(0.42, 0.98, filament);
    float body = smoothstep(0.0, 0.12, y) * (1.0 - smoothstep(0.52, 1.0, y));
    float edge = pow(1.0 - abs(dot(normalize(in.normalView), normalize(in.viewDir))), 1.4);
    float alpha = (body * 0.25 + filament * body * 0.5 + edge * body * 0.22) * u.params.x;
    if (alpha < 0.002) discard_fragment();
    float3 col = mix(u.core.rgb, u.edge.rgb, clamp(y * 0.7 + filament * 0.45, 0.0, 1.0));
    return float4(col, clamp(alpha, 0.0, 1.0));
}

// ── post: depth of field ─────────────────────────────────────────────────

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostOut post_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 p = positions[vid];
    PostOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = p * float2(0.5, -0.5) + 0.5;
    return out;
}

static inline float viewDepthFromDepth(float d, float nearP, float farP) {
    // Metal [0,1] depth → positive view distance.
    float zs = farP / (nearP - farP);
    float v = (zs * nearP) / (d + zs);
    return clamp(v, 0.0, farP);
}

fragment float4 dof_fragment(PostOut in [[stage_in]],
                             texture2d<float> sceneTex [[texture(0)]],
                             constant DofUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    // Analytic scene depth: the front surface of the globe. This mirrors the
    // focal model used by the web's depth pass without paying for a second
    // scene render.
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float3 ray = normalize(u.cameraForward.xyz
                           + u.cameraRight.xyz * (ndc.x * u.depthParams.x * u.params.w)
                           + u.cameraUp.xyz * (ndc.y * u.depthParams.x));
    float3 oc = u.cameraPos.xyz;
    float b = dot(oc, ray);
    float c = dot(oc, oc) - u.depthParams.y * u.depthParams.y;
    float disc = b * b - c;
    float viewZ = u.depthParams.w;
    if (disc > 0.0) {
        float t = -b - sqrt(disc);
        if (t > 0.001) {
            viewZ = t * max(0.0, dot(ray, u.cameraForward.xyz));
        }
    }
    float factor = u.params.x - viewZ;
    float blur = clamp(factor * u.params.y, -u.params.z, u.params.z);
    float2 aspectcorrect = float2(1.0, u.params.w);

    float2 d7 = blur * 0.7;
    float2 d4 = blur * 0.4;

    float4 col = sceneTex.sample(smp, uv);
    float2 ring16[16] = {
        float2(0.0, 0.4), float2(0.15, 0.37), float2(0.29, 0.29), float2(-0.37, 0.15),
        float2(0.40, 0.0), float2(0.37, -0.15), float2(0.29, -0.29), float2(-0.15, -0.37),
        float2(0.0, -0.4), float2(-0.15, 0.37), float2(-0.29, 0.29), float2(0.37, 0.15),
        float2(-0.4, 0.0), float2(-0.37, -0.15), float2(-0.29, -0.29), float2(0.15, -0.37)
    };
    float2 ring8[8] = {
        float2(0.15, 0.37), float2(-0.37, 0.15), float2(0.37, -0.15), float2(-0.15, -0.37),
        float2(-0.15, 0.37), float2(0.37, 0.15), float2(-0.37, -0.15), float2(0.15, -0.37)
    };
    for (int i = 0; i < 16; i++) {
        col += sceneTex.sample(smp, uv + ring16[i] * aspectcorrect * blur);
    }
    for (int i = 0; i < 8; i++) {
        col += sceneTex.sample(smp, uv + ring8[i] * aspectcorrect * d7);
    }
    col += sceneTex.sample(smp, uv + float2(0.29, 0.29) * aspectcorrect * d4);
    col += sceneTex.sample(smp, uv + float2(-0.29, -0.29) * aspectcorrect * d4);
    col /= 27.0;
    col.a = 1.0;
    return col;
}

// ── post: bloom ──────────────────────────────────────────────────────────

fragment float4 bright_fragment(PostOut in [[stage_in]],
                                texture2d<float> sceneTex [[texture(0)]],
                                constant BrightUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 texel = sceneTex.sample(smp, in.uv);
    float v = dot(texel.rgb, float3(0.2126, 0.7152, 0.0722));
    float alpha = smoothstep(u.params.x, u.params.x + u.params.y, v);
    return float4(texel.rgb * alpha, 1.0);
}

fragment float4 blur_fragment(PostOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant BlurUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 inv = u.directionSize.zw;
    float2 dir = u.directionSize.xy * inv;
    float4 sum = src.sample(smp, in.uv) * u.params.y;
    int count = int(u.params.x);
    for (int i = 0; i < 11; i++) {
        if (i >= count) break;
        int bank = i / 4;
        int slot = i % 4;
        float off = u.offsets[bank][slot];
        float w = u.weights[bank][slot];
        sum += src.sample(smp, in.uv + dir * off) * w;
        sum += src.sample(smp, in.uv - dir * off) * w;
    }
    return sum;
}

fragment float4 bloom_composite_fragment(PostOut in [[stage_in]],
                                         texture2d<float> mip0 [[texture(0)]],
                                         texture2d<float> mip1 [[texture(1)]],
                                         texture2d<float> mip2 [[texture(2)]],
                                         texture2d<float> mip3 [[texture(3)]],
                                         texture2d<float> mip4 [[texture(4)]],
                                         constant BloomUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float radius = u.params.y;
    float factors[5] = { 1.0, 0.8, 0.6, 0.4, 0.2 };
    float3 mips[5];
    mips[0] = mip0.sample(smp, in.uv).rgb;
    mips[1] = mip1.sample(smp, in.uv).rgb;
    mips[2] = mip2.sample(smp, in.uv).rgb;
    mips[3] = mip3.sample(smp, in.uv).rgb;
    mips[4] = mip4.sample(smp, in.uv).rgb;
    float3 bloom = float3(0.0);
    for (int i = 0; i < 5; i++) {
        float mirror = 1.2 - factors[i];
        float f = mix(factors[i], mirror, radius);
        bloom += f * mips[i];
    }
    bloom *= 3.0 * u.params.x;
    return float4(bloom, 1.0);
}

// ── final composite: output pass + vignette shader + CSS atmosphere ──────

fragment float4 final_fragment(PostOut in [[stage_in]],
                               texture2d<float> dofTex [[texture(0)]],
                               texture2d<float> bloomTex [[texture(1)]],
                               constant FinalUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float3 color = dofTex.sample(smp, uv).rgb;
    if (u.params.y > 0.5) {
        color += bloomTex.sample(smp, uv).rgb;
    }
    color = acesFilm(color, 0.98);
    color = linearToSRGB(color);

    // vignetteShader (applied after OutputPass in the web composer)
    float2 p = uv - 0.5;
    p.x *= u.params.z / max(1.0, u.params.w);
    float vig = 1.0 - smoothstep(0.3, 1.06, length(p));
    color *= mix(0.7, 1.0, vig);
    float grain = fract(sin(dot(uv * float2(u.params.z, u.params.w) + u.params.x * 60.0,
                                float2(12.9898, 78.233))) * 43758.5453);
    color += (grain - 0.5) * 0.008;

    // .vignette DOM overlay: radial + linear shadows.
    float2 ellipse = float2((uv.x - 0.5) / 0.72, (uv.y - 0.45) / 0.68);
    float radialAlpha = smoothstep(0.38, 1.0, length(ellipse)) * 0.5;
    float topAlpha = 0.2 * (1.0 - clamp(uv.y / 0.2, 0.0, 1.0));
    float bottomAlpha = 0.46 * smoothstep(0.68, 1.0, uv.y);
    float linearAlpha = 1.0 - (1.0 - topAlpha) * (1.0 - bottomAlpha);
    float overlayAlpha = 1.0 - (1.0 - radialAlpha) * (1.0 - linearAlpha);
    float3 overlayColor = float3(4.0, 2.0, 1.0) / 255.0;
    color = mix(color, overlayColor, overlayAlpha);

    // .grain overlay (opacity .068, mix-blend-mode: overlay)
    float n = hash12(floor(uv * u.params.zw) + floor(u.params.x * 0.001));
    float3 overlayGrain = n > 0.5 ? (1.0 - 2.0 * (1.0 - color) * (1.0 - n)) : 2.0 * color * n;
    color = mix(color, overlayGrain, 0.068 * 0.5);

    return float4(color, 1.0);
}
