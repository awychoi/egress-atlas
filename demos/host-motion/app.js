(function () {
  'use strict';

  // ── tiny 3D / math kit ────────────────────────────────────────────────
  const TAU = Math.PI * 2;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const clamp01 = (v) => clamp(v, 0, 1);
  const lerp = (a, b, t) => a + (b - a) * t;
  const smoothstep = (a, b, v) => {
    const t = clamp01((v - a) / (b - a));
    return t * t * (3 - 2 * t);
  };
  const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);
  const easeInCubic = (t) => t * t * t;
  const easeInOutCubic = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const easeOutQuint = (t) => 1 - Math.pow(1 - t, 5);
  const easeOutBack = (t, o = 1.4) => {
    const c3 = o + 1;
    const p = t - 1;
    return 1 + c3 * p * p * p + o * p * p;
  };
  const easeInOutSine = (t) => -(Math.cos(Math.PI * t) - 1) / 2;

  const V = (x = 0, y = 0, z = 0) => ({ x, y, z });
  const vadd = (a, b) => V(a.x + b.x, a.y + b.y, a.z + b.z);
  const vsub = (a, b) => V(a.x - b.x, a.y - b.y, a.z - b.z);
  const vmul = (a, s) => V(a.x * s, a.y * s, a.z * s);
  const vdot = (a, b) => a.x * b.x + a.y * b.y + a.z * b.z;
  const vcross = (a, b) => V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
  const vlen = (a) => Math.hypot(a.x, a.y, a.z);
  const vnorm = (a) => {
    const l = vlen(a);
    return l > 1e-7 ? vmul(a, 1 / l) : V(0, 1, 0);
  };
  const vlerp = (a, b, t) => V(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t));
  const vdist = (a, b) => vlen(vsub(a, b));

  function orthoBasis(normal) {
    const n = vnorm(normal);
    const helper = Math.abs(n.y) > 0.92 ? V(1, 0, 0) : V(0, 1, 0);
    const t = vnorm(vcross(helper, n));
    const b = vnorm(vcross(n, t));
    return { n, t, b };
  }

  function rotateY(p, a) {
    const c = Math.cos(a);
    const s = Math.sin(a);
    return V(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
  }

  function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t = (t + Math.imul(t ^ (t >>> 7), t | 61)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // seeded hash helper for stable, flicker-free variation
  function hash01(n) {
    let x = Math.imul(n ^ 0x9e3779b9, 0x85ebca6b);
    x ^= x >>> 13;
    x = Math.imul(x, 0xc2b2ae35);
    x ^= x >>> 16;
    return (x >>> 0) / 4294967296;
  }

  // ── colour kit ────────────────────────────────────────────────────────
  const C = {
    bg: '#03090c',
    ink: '#eafbff',
    host: '#5fd8e8',
    hostDeep: '#134f5c',
    hostDim: '#2a9fb5',
    ice: '#d6f7ff',
    mint: '#7ff0d0',
    app: '#4fe0c8',
    appHot: '#c9fff4',
    appDeep: '#1b6f68',
    appHover: '#8cf5e2',
    dest: '#6f9bff',
    destHot: '#d6e4ff',
    destDeep: '#2b4f8f',
    destHover: '#9bb8ff',
    violet: '#b79bff',
    violetHot: '#d6c5ff',
    blue: '#8db4ff',
    white: '#f4feff',
    offWhite: '#e8fbff',
    text: '#eafbff',
    text2: '#c2e3ea',
    muted: '#8aa8b0',
    faint: '#38535b',
  };

  const rgbCache = new Map();
  function hexToRgb(hex) {
    let c = rgbCache.get(hex);
    if (c) return c;
    let h = hex.replace('#', '');
    if (h.length === 3) h = h.split('').map((ch) => ch + ch).join('');
    const n = parseInt(h, 16);
    c = { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
    rgbCache.set(hex, c);
    return c;
  }
  function rgba(hex, a) {
    const c = hexToRgb(hex);
    return `rgba(${c.r},${c.g},${c.b},${Math.max(0, Math.min(1, a))})`;
  }
  function mixHex(a, b, t) {
    const ca = hexToRgb(a);
    const cb = hexToRgb(b);
    return `rgb(${Math.round(lerp(ca.r, cb.r, t))},${Math.round(lerp(ca.g, cb.g, t))},${Math.round(lerp(ca.b, cb.b, t))})`;
  }

  // ── parameters / DOM ──────────────────────────────────────────────────
  const params = new URLSearchParams(location.search);
  const FREEZE = params.has('freeze');
  const CLEAN = params.get('ui') === '0' || params.get('clean') === '1';
  const FREEZE_T = Math.max(0, parseFloat(params.get('t') || '0.5') || 0);
  const NO_AUTO = params.get('auto') === '0' || FREEZE;
  const REDUCED = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const canvas = document.getElementById('scene');
  const ctx = canvas.getContext('2d', { alpha: true });
  const groupsEl = document.getElementById('groups');
  const notesEl = document.getElementById('notes');
  const takeNoEl = document.getElementById('takeNo');
  const takeNameEl = document.getElementById('takeName');
  const takeKindEl = document.getElementById('takeKind');
  const takeTagEl = document.getElementById('takeTag');
  const takeDurEl = document.getElementById('takeDur');
  const takeRecoilEl = document.getElementById('takeRecoil');
  const recoilFillEl = document.getElementById('recoilFill');
  const recoilScaleEl = document.getElementById('recoilScale');
  const recoilTrackEl = document.getElementById('recoilTrack');
  const motionLabelEl = document.getElementById('motionLabel');
  const motionNoteEl = document.getElementById('motionNote');
  const takeLookEl = document.getElementById('takeLook');
  const targetLineEl = document.getElementById('targetLine');
  const incomingLineEl = document.getElementById('incomingLine');
  const liveStateEl = document.getElementById('liveState');
  const liveTimeEl = document.getElementById('liveTime');
  const liveFillEl = document.getElementById('liveFill');
  const dockFillEl = document.getElementById('dockFill');
  const captionBodyEl = document.querySelector('.caption-body');
  const captionEl = document.getElementById('caption');
  const targetSegEl = document.getElementById('targetSeg');
  const playBtn = document.getElementById('playBtn');
  const prevBtn = document.getElementById('prevBtn');
  const nextBtn = document.getElementById('nextBtn');
  const slowBtn = document.getElementById('slowBtn');
  const reelBtn = document.getElementById('reelBtn');
  const toastEl = document.getElementById('toast');
  const cleanTakeEl = document.getElementById('cleanTake');

  if (CLEAN) document.body.classList.add('clean');
  if (FREEZE) document.body.classList.add('freeze');

  const view = { w: 0, h: 0, dpr: 1 };
  const cam = {
    yaw: parseFloat(params.get('yaw') || '0.46') || 0.46,
    pitch: parseFloat(params.get('pitch') || '0.30') || 0.30,
    dist: parseFloat(params.get('dist') || '33.5') || 33.5,
    target: V(0, 0.15, 0),
    fov: 35,
  };
  let camState = null;
  let stageCenterX = 0;

  const GLOBE_R = 6;
  const APP_LIFT = 0.33;

  let simTime = 0;
  let lastTime = 0;
  let running = !FREEZE;
  let shakeAmp = 0;
  let uiAccum = 0;
  let bootPlayed = NO_AUTO;
  let reelDue = 0;
  let reelPrimed = false;
  let toastUntil = 0;

  const state = {
    cat: 'impact',
    idx: 0,
    target: 'both',
    focusApp: 0,
    focusDomain: 0,
    slow: false,
    reel: false,
    hover: null,
    dragging: false,
    dragMoved: 0,
    lastPointer: { x: 0, y: 0 },
    reduced: REDUCED,
  };
  if (['app', 'domain', 'both'].includes(params.get('target'))) state.target = params.get('target');
  if (params.has('study') && ['impact', 'appear', 'disappear'].includes(params.get('study'))) state.cat = params.get('study');
  if (params.has('variant')) state.idx = clamp(parseInt(params.get('variant'), 10) || 0, 0, 3);

  // ── world data ────────────────────────────────────────────────────────
  const APP_DEFS = [
    { id: 'brave', name: 'Brave Browser', short: 'Brave', normal: [-0.47, 0.42, 0.78] },
    { id: 'push', name: 'Apple Push', short: 'Push', normal: [0.30, 0.72, 0.63] },
    { id: 'dns', name: 'DNS resolver', short: 'DNS', normal: [0.86, 0.18, 0.48] },
    { id: 'tailscale', name: 'Tailscale', short: 'Tailscale', normal: [-0.80, -0.05, 0.60] },
    { id: 'code', name: 'Code', short: 'Code', normal: [0.52, -0.62, 0.59] },
    { id: 'atlas', name: 'Egress Atlas', short: 'Atlas', normal: [-0.12, -0.80, 0.59] },
  ];

  const DOMAIN_DEFS = [
    { id: 'github', name: 'github.com', short: 'github.com', dir: [-0.35, 0.18, 0.92], dist: 3.15, radius: 0.255 },
    { id: 'api', name: 'api.github.com', short: 'api.github', dir: [-0.06, 0.44, 0.90], dist: 2.25, radius: 0.215 },
    { id: 'jsdelivr', name: 'cdn.jsdelivr.net', short: 'jsdelivr', dir: [0.40, 0.66, 0.64], dist: 3.75, radius: 0.26 },
    { id: 'slack', name: 'slack.com', short: 'slack.com', dir: [-0.72, -0.08, 0.69], dist: 2.95, radius: 0.225 },
    { id: 'time', name: 'time.apple.com', short: 'time.apple', dir: [0.54, -0.52, 0.66], dist: 3.55, radius: 0.235 },
    { id: 'icloud', name: 'gateway.icloud.com', short: 'icloud', dir: [-0.08, -0.62, 0.78], dist: 2.20, radius: 0.205 },
  ];

  const WIRE_PAIRS = [
    [0, 0], [0, 1],
    [1, 2],
    [2, 2],
    [3, 3], [3, 5],
    [4, 4], [4, 2],
    [5, 5],
  ];

  function makeApps() {
    return APP_DEFS.map((def, index) => {
      const normal = vnorm(V(def.normal[0], def.normal[1], def.normal[2]));
      const p = vmul(normal, GLOBE_R);
      return {
        type: 'app',
        index,
        id: def.id,
        name: def.name,
        short: def.short,
        p,
        normal,
        radius: 0.15,
        color: C.app,
        hot: C.appHot,
        deep: C.appDeep,
        orbit: C.hostDim,
        presence: 1,
        resting: 1,
        presenceFx: null,
        restoreAt: 0,
        recoil: V(),
        recoilVel: V(),
        recoilActive: false,
        flash: 99,
        warp: { sx: 1, sy: 1, rot: 0 },
        clip: null,
        phase: hash01(index * 31 + 5) * TAU,
        seed: 900 + index * 53,
      };
    });
  }

  function makeDomains() {
    return DOMAIN_DEFS.map((def, index) => {
      const dir = vnorm(V(def.dir[0], def.dir[1], def.dir[2]));
      const p = vmul(dir, def.dist);
      return {
        type: 'domain',
        index,
        id: def.id,
        name: def.name,
        short: def.short,
        p,
        normal: dir,
        radius: def.radius,
        color: C.dest,
        hot: C.destHot,
        deep: C.destDeep,
        orbit: C.destDeep,
        presence: 1,
        resting: 1,
        presenceFx: null,
        restoreAt: 0,
        recoil: V(),
        recoilVel: V(),
        recoilActive: false,
        flash: 99,
        warp: { sx: 1, sy: 1, rot: 0 },
        clip: null,
        phase: hash01(index * 71 + 23) * TAU,
        seed: 1700 + index * 37,
      };
    });
  }

  const apps = makeApps();
  const domains = makeDomains();
  const bodies = [...apps, ...domains];
  const appByIndex = (i) => apps[clamp(i, 0, apps.length - 1)];
  const domainByIndex = (i) => domains[clamp(i, 0, domains.length - 1)];

  function bodyAnchor(b) {
    return b.type === 'app' ? vadd(b.p, vmul(b.normal, APP_LIFT)) : b.p;
  }
  function bodyVisual(b) {
    return vadd(bodyAnchor(b), b.recoil);
  }

  function bowControl(a, b, extra = 1.0) {
    const mid = vlerp(a, b, 0.5);
    const radial = vnorm(mid);
    const distance = vdist(a, b);
    return vadd(mid, vmul(radial, Math.min(1.4, 0.32 + distance * 0.16) * extra));
  }
  function quad(p0, p1, p2, t) {
    const it = 1 - t;
    return V(
      it * it * p0.x + 2 * it * t * p1.x + t * t * p2.x,
      it * it * p0.y + 2 * it * t * p1.y + t * t * p2.y,
      it * it * p0.z + 2 * it * t * p1.z + t * t * p2.z
    );
  }

  function cubic(p0, p1, p2, p3, t) {
    const it = 1 - t;
    const a = it * it * it;
    const b = 3 * it * it * t;
    const c = 3 * it * t * t;
    const d = t * t * t;
    return V(
      a * p0.x + b * p1.x + c * p2.x + d * p3.x,
      a * p0.y + b * p1.y + c * p2.y + d * p3.y,
      a * p0.z + b * p1.z + c * p2.z + d * p3.z
    );
  }

  function drawGlowAtCenter(env, sizeWorld, color, alpha) {
    if (alpha <= 0.003) return;
    const pr = project(env.center);
    if (!pr) return;
    glowAt(pr.x, pr.y, Math.max(2, sizeWorld * pr.s), color, alpha);
  }

  const wires = WIRE_PAIRS.map(([ai, di], index) => {
    const a = appByIndex(ai);
    const d = domainByIndex(di);
    const start = bodyAnchor(a);
    const end = bodyAnchor(d);
    const control = bowControl(start, end);
    const pts = [];
    for (let i = 0; i <= 36; i++) pts.push(quad(start, control, end, i / 36));
    return {
      app: a,
      domain: d,
      start,
      end,
      control,
      pts,
      phase: hash01(index * 19 + 3) * TAU,
      seed: index * 97 + 11,
    };
  });

  const IDLE_SIGNALS = [
    { wire: 0, dir: 1, speed: 0.19, phase: 0.12 },
    { wire: 2, dir: -1, speed: 0.15, phase: 0.58 },
    { wire: 4, dir: 1, speed: 0.22, phase: 0.31 },
    { wire: 6, dir: -1, speed: 0.17, phase: 0.77 },
    { wire: 8, dir: 1, speed: 0.13, phase: 0.46 },
  ];

  // ── camera ────────────────────────────────────────────────────────────
  function rebuildCamera() {
    const cp = Math.cos(cam.pitch);
    const sp = Math.sin(cam.pitch);
    const cy = Math.cos(cam.yaw);
    const sy = Math.sin(cam.yaw);
    const pos = V(
      cam.target.x + cam.dist * sy * cp,
      cam.target.y + cam.dist * sp,
      cam.target.z + cam.dist * cy * cp
    );
    const forward = vnorm(vsub(cam.target, pos));
    const right = vnorm(vcross(forward, V(0, 1, 0)));
    const up = vnorm(vcross(right, forward));
    const f = (view.h * 0.5) / Math.tan((cam.fov * Math.PI) / 360);
    camState = {
      pos,
      forward,
      right,
      up,
      f,
      cx: stageCenterX || view.w * 0.5,
      cy: view.h * 0.5 + view.h * 0.012,
      origin: pos,
    };
  }

  function project(p) {
    if (!camState) return null;
    const d = vsub(p, camState.pos);
    const z = vdot(d, camState.forward);
    if (z <= 0.03) return null;
    return {
      x: camState.cx + (vdot(d, camState.right) * camState.f) / z,
      y: camState.cy - (vdot(d, camState.up) * camState.f) / z,
      z,
      s: camState.f / z,
    };
  }

  function visibleOnScreen(pr, margin = 140) {
    return pr && pr.x > -margin && pr.x < view.w + margin && pr.y > -margin && pr.y < view.h + margin;
  }

  // ── starfield / dust ──────────────────────────────────────────────────
  let stars = [];
  let dust = [];
  function seedField() {
    const r = mulberry32(0xa71a5);
    stars = [];
    const count = Math.round(Math.min(210, Math.max(110, (view.w * view.h) / 9000)));
    for (let i = 0; i < count; i++) {
      stars.push({
        x: r() * view.w,
        y: r() * view.h,
        size: 0.45 + r() * 1.05,
        base: 0.08 + r() * 0.38,
        phase: r() * TAU,
        speed: 0.18 + r() * 0.55,
        tint: r() > 0.82 ? C.host : r() > 0.94 ? C.violet : '#eafbff',
      });
    }
    dust = [];
    const dr = mulberry32(0x51a7);
    for (let i = 0; i < 64; i++) {
      const dir = vnorm(V(dr() * 2 - 1, dr() * 2 - 1, dr() * 2 - 1));
      dust.push({
        dir,
        dist: GLOBE_R * (1.35 + dr() * 1.4),
        size: 0.012 + dr() * 0.028,
        alpha: 0.08 + dr() * 0.3,
        tint: dr() > 0.75 ? C.violet : dr() > 0.4 ? C.host : '#dff8ff',
        phase: dr() * TAU,
      });
    }
  }

  function resize() {
    view.w = Math.max(320, window.innerWidth);
    view.h = Math.max(320, window.innerHeight);
    view.dpr = Math.min(1.75, window.devicePixelRatio || 1);
    canvas.width = Math.round(view.w * view.dpr);
    canvas.height = Math.round(view.h * view.dpr);
    ctx.setTransform(view.dpr, 0, 0, view.dpr, 0, 0);
    stageCenterX = view.w * 0.5;
    if (view.w > 920) {
      const lib = document.getElementById('library');
      const notes = document.getElementById('notes');
      let left = 0;
      let right = view.w;
      if (lib) {
        const r = lib.getBoundingClientRect();
        if (r.width > 0) left = r.right;
      }
      if (notes && getComputedStyle(notes).display !== 'none') {
        const r = notes.getBoundingClientRect();
        if (r.width > 0) right = r.left;
      }
      if (right - left > 320) stageCenterX = (left + right) / 2;
    }
    rebuildCamera();
    seedField();
  }

  // ── glow / line primitives ────────────────────────────────────────────
  const glowCache = new Map();
  function glowSprite(color) {
    let c = glowCache.get(color);
    if (c) return c;
    c = document.createElement('canvas');
    c.width = c.height = 128;
    const g = c.getContext('2d');
    const grad = g.createRadialGradient(64, 64, 0, 64, 64, 64);
    grad.addColorStop(0, 'rgba(255,255,255,0.95)');
    grad.addColorStop(0.09, rgba(color, 0.9));
    grad.addColorStop(0.3, rgba(color, 0.34));
    grad.addColorStop(0.62, rgba(color, 0.09));
    grad.addColorStop(1, rgba(color, 0));
    g.fillStyle = grad;
    g.fillRect(0, 0, 128, 128);
    glowCache.set(color, c);
    return c;
  }

  function glowAt(x, y, size, color, alpha) {
    if (alpha <= 0.003 || size < 1) return;
    ctx.globalAlpha = clamp01(alpha);
    ctx.drawImage(glowSprite(color), x - size / 2, y - size / 2, size, size);
    ctx.globalAlpha = 1;
  }

  function glowWorld(p, sizeWorld, color, alpha) {
    const pr = project(p);
    if (!pr || alpha <= 0.003) return;
    glowAt(pr.x, pr.y, Math.max(2, sizeWorld * pr.s), color, alpha);
  }

  function line3(a, b, color, alpha, width = 1) {
    if (alpha <= 0.003) return;
    const A = project(a);
    const B = project(b);
    if (!A || !B) return;
    ctx.strokeStyle = rgba(color, alpha);
    ctx.lineWidth = width;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(A.x, A.y);
    ctx.lineTo(B.x, B.y);
    ctx.stroke();
  }

  function pathFromWorld(points) {
    ctx.beginPath();
    let pen = false;
    let any = false;
    for (let i = 0; i < points.length; i++) {
      const pr = project(points[i]);
      if (!pr) {
        pen = false;
        continue;
      }
      if (!pen) {
        ctx.moveTo(pr.x, pr.y);
        pen = true;
      } else {
        ctx.lineTo(pr.x, pr.y);
      }
      any = true;
    }
    return any;
  }

  function strokeWorldPath(points, color, alpha, width, cap = 'round') {
    if (alpha <= 0.002) return;
    if (!pathFromWorld(points)) return;
    ctx.lineCap = cap;
    ctx.lineJoin = 'round';
    ctx.strokeStyle = rgba(color, alpha);
    ctx.lineWidth = width;
    ctx.stroke();
  }

  function ringPoint(center, normal, radius, angle) {
    const { t, b } = orthoBasis(normal);
    return vadd(center, vadd(vmul(t, Math.cos(angle) * radius), vmul(b, Math.sin(angle) * radius)));
  }

  function ringPoints(center, normal, radius, segments = 80, spin = 0) {
    const { t, b } = orthoBasis(normal);
    const pts = [];
    for (let i = 0; i <= segments; i++) {
      const a = (i / segments) * TAU + spin;
      pts.push(vadd(center, vadd(vmul(t, Math.cos(a) * radius), vmul(b, Math.sin(a) * radius))));
    }
    return pts;
  }

  function strokeArc(center, normal, radius, start, sweep, color, alpha, width) {
    if (alpha <= 0.003) return;
    const pts = [];
    const steps = Math.max(12, Math.ceil((Math.abs(sweep) / TAU) * 90));
    for (let i = 0; i <= steps; i++) {
      pts.push(ringPoint(center, normal, radius, start + (sweep * i) / steps));
    }
    strokeWorldPath(pts, color, alpha, width);
  }

  // Draws a shock ring. `opts` times are in seconds, radii are in effect-radius units.
  function drawShock(env, opts) {
    const delay = opts.delay || 0;
    const a = env.age - delay;
    if (a < 0 || a >= opts.duration) return;
    const p = clamp01(a / opts.duration);
    const e = easeOutQuint(p);
    const R = lerp(opts.start, opts.end, e) * env.r;
    if (R < 0.002) return;
    const alpha = Math.pow(1 - p, 1.25) * (opts.opacity == null ? 1 : opts.opacity);
    if (alpha <= 0.004) return;
    const center = opts.offset ? vadd(env.center, opts.offset) : env.center;
    const widthWorld = Math.max(0.0015, (opts.thickness == null ? 0.035 : opts.thickness) * env.r * (1 - e * 0.66));
    drawShockRing(center, opts.normal || env.normal, R, opts.core || C.ice, opts.tail || C.violet, alpha, widthWorld, opts.rays || 0, opts.seed || 0, opts.hot || 0);
    if (opts.wake !== false) {
      drawShockRing(center, opts.normal || env.normal, R * 0.86, opts.core || C.ice, opts.tail || C.violet, alpha * 0.2, widthWorld * 2.7, 0, 0, opts.hot || 0);
    }
  }

  function drawShockRing(center, normal, radius, core, tail, alpha, widthWorld, rays, seed, hot) {
    const pr = project(center);
    if (!pr) return;
    const pts = ringPoints(center, normal, radius, 68);
    const sx = pr.s;
    const pxR = Math.max(2, radius * sx);
    const coreW = Math.max(1.15, widthWorld * sx * 1.7, pxR * 0.011);
    // The real renderer gets its neon edge from the bloom pass. Emulate that
    // with a wide, faint tail stroke under a narrow hot core.
    strokeWorldPath(pts, tail, alpha * 0.14, Math.max(8, pxR * 0.19));
    strokeWorldPath(pts, mixHex(tail, core, 0.42), alpha * 0.34, Math.max(3.4, pxR * 0.062));
    strokeWorldPath(pts, tail, alpha * 0.58, coreW * 2.5);
    strokeWorldPath(pts, core, alpha * 0.98, coreW);
    if (hot > 0) {
      strokeWorldPath(pts, mixHex(core, tail, hot), alpha * 0.5, coreW * 3.6);
    }
    // a few hot beads ride the ring so it never reads as a clean vector
    for (let i = 0; i < 7; i++) {
      const ang = hash01(seed * 577 + i * 97) * TAU;
      const pp = ringPoint(center, normal, radius * (0.985 + hash01(i + seed) * 0.03), ang);
      const ppr = project(pp);
      if (!ppr) continue;
      glowAt(ppr.x, ppr.y, Math.max(5, pxR * 0.13), mixHex(core, '#ffffff', 0.5), alpha * 0.32);
    }
    if (rays > 0) {
      const { t, b } = orthoBasis(normal);
      for (let i = 0; i < rays; i++) {
        const rnd = hash01(seed * 977 + i * 131);
        if (rnd < 0.38) continue;
        const ang = (i / rays) * TAU + seed * 0.37;
        const dir = vadd(vmul(t, Math.cos(ang)), vmul(b, Math.sin(ang)));
        const len = radius * (0.02 + rnd * 0.22);
        const a0 = vadd(center, vmul(dir, radius * 0.98));
        const a1 = vadd(center, vmul(dir, radius + len));
        line3(a0, a1, mixHex(core, tail, 0.4), alpha * (0.22 + rnd * 0.4), Math.max(0.6, coreW * 0.7));
      }
    }
    // a few bright points riding the ring keep it from reading as a clean vector
    for (let i = 0; i < 4; i++) {
      const ang = hash01(seed * 311 + i * 43) * TAU;
      const pp = ringPoint(center, normal, radius * (0.99 + hash01(i + seed) * 0.03), ang);
      glowWorld(pp, Math.max(0.012, widthWorld * 9), mixHex(core, '#ffffff', 0.35), alpha * 0.32);
    }
  }

  function drawFlash(env, opts) {
    const delay = opts.delay || 0;
    const a = env.age - delay;
    if (a < 0 || a >= opts.duration) return;
    const t = clamp01(a / opts.duration);
    const appear = clamp01(a / 0.012);
    const expand = 0.46 + easeOutCubic(t) * 0.9;
    const fade = Math.pow(1 - t, 2.1) * appear * (opts.opacity == null ? 1 : opts.opacity);
    const pr = project(env.center);
    if (!pr) return;
    const size = opts.size * env.r * expand * pr.s * 1.7;
    glowAt(pr.x, pr.y, Math.max(3, size), opts.color || C.white, fade * 0.92);
    glowAt(pr.x, pr.y, Math.max(3, size * 3.0), opts.halo || opts.color || C.violet, fade * 0.28);
  }

  // ── spark / shard / mote systems ──────────────────────────────────────
  function makeSparks(rng, count, r, o = {}) {
    const colors = o.colors || [C.ice, C.host, C.violet, C.white];
    const out = [];
    for (let i = 0; i < count; i++) {
      const angle = rng() * TAU;
      const speed = lerp(o.speed ? o.speed[0] : 1.6, o.speed ? o.speed[1] : 5.6, rng());
      out.push({
        angle,
        start: (o.start == null ? 0.3 : o.start) * r * (0.7 + rng() * 0.6),
        speed: speed * r,
        tangential: (rng() * 2 - 1) * (o.tangential == null ? 1.6 : o.tangential) * r,
        normalSpeed: (o.normalSpeed == null ? 0 : (rng() * 2 - 1) * o.normalSpeed) * r,
        drag: (o.drag == null ? 1.0 : o.drag) * (0.7 + rng() * 0.6),
        life: lerp(o.life ? o.life[0] : 0.35, o.life ? o.life[1] : 1.0, rng()),
        delay: lerp(o.delay ? o.delay[0] : 0, o.delay ? o.delay[1] : 0, rng()),
        size: lerp(o.size ? o.size[0] : 0.012, o.size ? o.size[1] : 0.045, rng()),
        color: colors[Math.floor(rng() * colors.length) % colors.length],
        twinkle: rng() * TAU,
      });
    }
    return out;
  }

  function drawSparks(sparks, age, env, opacity = 1) {
    if (!env.center) return;
    const { t, b } = orthoBasis(env.normal);
    for (let i = 0; i < sparks.length; i++) {
      const p = sparks[i];
      const a = age - p.delay;
      if (a < 0 || a > p.life) continue;
      const lifeT = a / p.life;
      const travel = (1 - Math.exp(-p.drag * a)) / p.drag;
      const travelPrev = (1 - Math.exp(-p.drag * Math.max(0, a - 0.016))) / p.drag;
      const dir = vadd(vmul(t, Math.cos(p.angle)), vmul(b, Math.sin(p.angle)));
      const tan = vadd(vmul(t, -Math.sin(p.angle)), vmul(b, Math.cos(p.angle)));
      const base = vadd(env.center, vadd(vmul(dir, p.start), vmul(tan, p.tangential * travel)));
      const pos = vadd(base, vmul(env.normal, p.normalSpeed * travel));
      const prev = vadd(
        vadd(env.center, vadd(vmul(dir, p.start), vmul(tan, p.tangential * travelPrev))),
        vmul(env.normal, p.normalSpeed * travelPrev)
      );
      const alpha = Math.pow(1 - lifeT, 1.35) * clamp01(a / 0.012) * opacity * (0.72 + 0.28 * Math.sin(p.twinkle + age * 23));
      if (alpha <= 0.004) continue;
      const A = project(prev);
      const B = project(pos);
      if (!A || !B) continue;
      const px = Math.max(1.0, p.size * B.s * 2.5);
      ctx.strokeStyle = rgba(p.color, alpha);
      ctx.lineWidth = px;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(A.x, A.y);
      ctx.lineTo(B.x, B.y);
      ctx.stroke();
      if (p.size > 0.022) glowAt(B.x, B.y, Math.max(4, p.size * B.s * 9), p.color, alpha * 0.4);
      ctx.fillStyle = rgba(C.white, alpha * 0.8);
      ctx.beginPath();
      ctx.arc(B.x, B.y, Math.max(0.6, px * 0.32), 0, TAU);
      ctx.fill();
    }
  }

  function makeShards(rng, count, r, o = {}) {
    const colors = o.colors || [C.ice, C.violet, C.host, C.white];
    const out = [];
    for (let i = 0; i < count; i++) {
      out.push({
        angle: rng() * TAU,
        start: (o.start == null ? 0.7 : o.start) * r * (0.75 + rng() * 0.5),
        speed: lerp(o.speed ? o.speed[0] : 1.1, o.speed ? o.speed[1] : 3.4, rng()) * r,
        drift: (rng() * 2 - 1) * (o.drift == null ? 0.25 : o.drift) * r,
        drag: 0.35 + rng() * 0.6,
        spin: (rng() * 2 - 1) * 8,
        phase: rng() * TAU,
        len: lerp(o.len ? o.len[0] : 0.3, o.len ? o.len[1] : 0.7, rng()) * r,
        wide: lerp(o.wide ? o.wide[0] : 0.035, o.wide ? o.wide[1] : 0.1, rng()) * r,
        delay: lerp(o.delay ? o.delay[0] : 0, o.delay ? o.delay[1] : 0, rng()),
        color: colors[Math.floor(rng() * colors.length) % colors.length],
      });
    }
    return out;
  }

  function drawShards(shards, age, env, opacity = 1) {
    const { t, b } = orthoBasis(env.normal);
    for (const s of shards) {
      const a = age - s.delay;
      if (a <= 0 || a > 1.4) continue;
      const travel = (1 - Math.exp(-s.drag * a)) / s.drag;
      const radial = vadd(vmul(t, Math.cos(s.angle)), vmul(b, Math.sin(s.angle)));
      const tangent = vadd(vmul(t, -Math.sin(s.angle)), vmul(b, Math.cos(s.angle)));
      const center = vadd(env.center, vadd(vmul(radial, s.start + s.speed * travel), vmul(env.normal, s.drift * Math.min(1, a * 2.2))));
      const spin = s.phase + s.spin * a;
      const rdir = vadd(vmul(radial, Math.cos(spin)), vmul(tangent, Math.sin(spin)));
      const side = vadd(vmul(radial, -Math.sin(spin)), vmul(tangent, Math.cos(spin)));
      const fade = (1 - smoothstep(0.55, 1.35, a)) * clamp01(a / 0.035) * opacity;
      if (fade <= 0.004) continue;
      const p0 = vadd(center, vmul(rdir, s.len * 0.62));
      const p1 = vadd(vadd(center, vmul(side, s.wide * 0.5)), vmul(rdir, s.len * 0.1));
      const p2 = vadd(center, vmul(rdir, -s.len * 0.42));
      const p3 = vadd(vadd(center, vmul(side, -s.wide * 0.5)), vmul(rdir, s.len * 0.1));
      const A = project(p0), B = project(p1), Cc = project(p2), D = project(p3);
      if (!A || !B || !Cc || !D) continue;
      ctx.fillStyle = rgba(s.color, fade * 0.8);
      ctx.beginPath();
      ctx.moveTo(A.x, A.y);
      ctx.lineTo(B.x, B.y);
      ctx.lineTo(Cc.x, Cc.y);
      ctx.lineTo(D.x, D.y);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = rgba(mixHex(s.color, '#ffffff', 0.4), fade * 0.5);
      ctx.lineWidth = 0.7;
      ctx.stroke();
    }
  }

  function makeMotes(rng, count, r, o = {}) {
    const colors = o.colors || [C.ice, C.host, C.violet];
    const out = [];
    for (let i = 0; i < count; i++) {
      out.push({
        angle: rng() * TAU,
        radius: lerp(o.radius ? o.radius[0] : 2.2, o.radius ? o.radius[1] : 3.6, rng()) * r,
        spin: (o.spin == null ? 0.8 : o.spin) * (0.6 + rng() * 0.9) * (rng() > 0.15 ? 1 : -1),
        normal: (rng() * 2 - 1) * (o.normal == null ? 1.2 : o.normal) * r,
        size: lerp(o.size ? o.size[0] : 0.012, o.size ? o.size[1] : 0.036, rng()),
        delay: lerp(0, o.delay || 0, rng()),
        color: colors[Math.floor(rng() * colors.length) % colors.length],
        phase: rng() * TAU,
      });
    }
    return out;
  }

  // ── globe + environment ───────────────────────────────────────────────
  function drawStars() {
    ctx.globalCompositeOperation = 'source-over';
    for (let i = 0; i < stars.length; i++) {
      const s = stars[i];
      const twinkle = 0.68 + 0.32 * Math.sin(simTime * s.speed + s.phase);
      const alpha = s.base * twinkle;
      ctx.fillStyle = rgba(s.tint, alpha);
      ctx.fillRect(s.x, s.y, s.size, s.size);
    }
    // a handful of brighter stars with tiny cross flares
    for (let i = 0; i < stars.length; i += 37) {
      const s = stars[i];
      const a = s.base * 0.7 * (0.7 + 0.3 * Math.sin(simTime * s.speed + s.phase));
      if (a < 0.14) continue;
      ctx.strokeStyle = rgba(s.tint, a * 0.45);
      ctx.lineWidth = 0.6;
      ctx.beginPath();
      ctx.moveTo(s.x - 2.8, s.y);
      ctx.lineTo(s.x + 2.8, s.y);
      ctx.moveTo(s.x, s.y - 2.8);
      ctx.lineTo(s.x, s.y + 2.8);
      ctx.stroke();
    }
    ctx.globalCompositeOperation = 'lighter';
  }

  function drawDust() {
    ctx.globalCompositeOperation = 'lighter';
    for (const d of dust) {
      const p = vmul(d.dir, d.dist);
      const pr = project(p);
      if (!pr || !visibleOnScreen(pr, 80)) continue;
      const a = d.alpha * (0.65 + 0.35 * Math.sin(simTime * 0.35 + d.phase));
      const sz = Math.max(0.7, Math.min(2.2, d.size * pr.s));
      ctx.fillStyle = rgba(d.tint, a);
      ctx.beginPath();
      ctx.arc(pr.x, pr.y, sz * 0.5, 0, TAU);
      ctx.fill();
    }
  }

  function drawGlobe() {
    const center = V(0, 0, 0);
    const prc = project(center);
    if (!prc) return;
    const rPx = GLOBE_R * prc.s;

    // atmosphere fill (opaque-ish, so the interior has a body)
    ctx.globalCompositeOperation = 'source-over';
    const atmo = ctx.createRadialGradient(prc.x, prc.y, rPx * 0.18, prc.x, prc.y, rPx * 1.06);
    atmo.addColorStop(0, 'rgba(8,27,34,0.10)');
    atmo.addColorStop(0.65, 'rgba(6,23,29,0.22)');
    atmo.addColorStop(0.93, 'rgba(13,43,52,0.32)');
    atmo.addColorStop(0.985, 'rgba(35,93,108,0.16)');
    atmo.addColorStop(1, 'rgba(95,216,232,0)');
    ctx.fillStyle = atmo;
    ctx.beginPath();
    ctx.arc(prc.x, prc.y, rPx * 1.06, 0, TAU);
    ctx.fill();

    ctx.globalCompositeOperation = 'lighter';

    // wide atmospheric bloom
    glowAt(prc.x, prc.y, rPx * 2.9, C.hostDim, 0.075);
    glowAt(prc.x, prc.y, rPx * 1.22, C.host, 0.035);

    // two giant faint orbital shells
    const shellA = ringPoints(center, vnorm(V(0.35, 0.9, 0.2)), GLOBE_R * 1.07, 72);
    const shellB = ringPoints(center, vnorm(V(-0.4, 0.25, 0.88)), GLOBE_R * 1.12, 72);
    strokeWorldPath(shellA, C.host, 0.045, 0.8);
    strokeWorldPath(shellB, C.host, 0.032, 0.8);

    // latitude / longitude grid, split into front and back paths
    const back = new Path2D();
    const front = new Path2D();
    const equator = new Path2D();
    const addSeg = (path, a, b) => {
      const A = project(a);
      const B = project(b);
      if (!A || !B) return;
      path.moveTo(A.x, A.y);
      path.lineTo(B.x, B.y);
    };
    const camPos = camState.pos;
    const isFront = (mid) => vdot(vnorm(mid), vnorm(vsub(camPos, mid))) > 0.02;

    for (let li = 0; li < 7; li++) {
      const lat = (-60 + li * 20) * (Math.PI / 180);
      const y = Math.sin(lat) * GLOBE_R;
      const rr = Math.cos(lat) * GLOBE_R;
      const path = li === 3 ? equator : front;
      for (let i = 0; i < 96; i++) {
        const a0 = (i / 96) * TAU;
        const a1 = ((i + 1) / 96) * TAU;
        const p0 = V(Math.cos(a0) * rr, y, Math.sin(a0) * rr);
        const p1 = V(Math.cos(a1) * rr, y, Math.sin(a1) * rr);
        const mid = vlerp(p0, p1, 0.5);
        addSeg(isFront(mid) ? path : back, p0, p1);
      }
    }
    for (let mi = 0; mi < 12; mi++) {
      const lon = (mi / 12) * TAU;
      for (let i = 0; i < 72; i++) {
        const l0 = -Math.PI / 2 + (i / 72) * Math.PI;
        const l1 = -Math.PI / 2 + ((i + 1) / 72) * Math.PI;
        const p0 = V(Math.cos(l0) * Math.cos(lon) * GLOBE_R, Math.sin(l0) * GLOBE_R, Math.cos(l0) * Math.sin(lon) * GLOBE_R);
        const p1 = V(Math.cos(l1) * Math.cos(lon) * GLOBE_R, Math.sin(l1) * GLOBE_R, Math.cos(l1) * Math.sin(lon) * GLOBE_R);
        const mid = vlerp(p0, p1, 0.5);
        addSeg(isFront(mid) ? front : back, p0, p1);
      }
    }
    ctx.lineCap = 'round';
    ctx.strokeStyle = rgba(C.hostDim, 0.16);
    ctx.lineWidth = 0.7;
    ctx.stroke(back);
    ctx.strokeStyle = rgba(C.host, 0.13);
    ctx.lineWidth = 0.9;
    ctx.stroke(front);
    ctx.strokeStyle = rgba(C.host, 0.05);
    ctx.lineWidth = 3.2;
    ctx.stroke(front);
    ctx.strokeStyle = rgba(C.ice, 0.20);
    ctx.lineWidth = 0.9;
    ctx.stroke(equator);

    // rim + limb
    ctx.strokeStyle = rgba(C.host, 0.20);
    ctx.lineWidth = 1.1;
    ctx.beginPath();
    ctx.arc(prc.x, prc.y, rPx, 0, TAU);
    ctx.stroke();
    ctx.strokeStyle = rgba(C.ice, 0.08);
    ctx.lineWidth = 3.4;
    ctx.beginPath();
    ctx.arc(prc.x, prc.y, rPx * 1.001, 0, TAU);
    ctx.stroke();
    glowAt(prc.x - rPx * 0.68, prc.y - rPx * 0.58, rPx * 0.55, C.host, 0.06);
    glowAt(prc.x + rPx * 0.82, prc.y + rPx * 0.45, rPx * 0.3, C.violet, 0.045);
  }

  // ── wires ─────────────────────────────────────────────────────────────
  let wireScreen = [];
  function updateWireScreen() {
    wireScreen = wires.map((w) => w.pts.map((p) => project(p)));
  }

  function wireHighlighted(w) {
    if (state.target === 'both') {
      return w.app === appByIndex(state.focusApp) || w.domain === domainByIndex(state.focusDomain);
    }
    return w.app === appByIndex(state.focusApp) || w.domain === domainByIndex(state.focusDomain);
  }

  function drawWires() {
    ctx.globalCompositeOperation = 'lighter';
    for (let wi = 0; wi < wires.length; wi++) {
      const pts = wireScreen[wi];
      if (!pts) continue;
      const highlighted = wireHighlighted(wires[wi]);
      const alpha = highlighted ? 0.17 : 0.073;
      ctx.beginPath();
      let pen = false;
      for (let i = 0; i < pts.length; i++) {
        const pr = pts[i];
        if (!pr) {
          pen = false;
          continue;
        }
        if (!pen) {
          ctx.moveTo(pr.x, pr.y);
          pen = true;
        } else {
          ctx.lineTo(pr.x, pr.y);
        }
      }
      if (!pen) continue;
      ctx.lineCap = 'round';
      ctx.strokeStyle = rgba(C.host, alpha * 0.5);
      ctx.lineWidth = 2.8;
      ctx.stroke();
      ctx.strokeStyle = rgba(C.host, alpha);
      ctx.lineWidth = 0.7;
      ctx.stroke();
    }

    // travelling signals keep the field alive between studies
    for (const s of IDLE_SIGNALS) {
      const w = wires[s.wire % wires.length];
      const pts = wireScreen[s.wire % wires.length];
      if (!pts) continue;
      const uRaw = (simTime * s.speed + s.phase) % 1;
      const u = s.dir > 0 ? uRaw : 1 - uRaw;
      drawSignalTrail(pts, u, s.dir > 0 ? C.violet : C.host, 0.72);
    }
  }

  function drawSignalTrail(pts, u, color, opacity) {
    const n = pts.length - 1;
    const idx = clamp(u, 0, 1) * n;
    const i0 = Math.floor(idx);
    const i1 = Math.min(n, i0 + 1);
    const f = idx - i0;
    const a = pts[i0];
    const b = pts[i1];
    if (!a || !b) return;
    const head = { x: lerp(a.x, b.x, f), y: lerp(a.y, b.y, f) };
    const back = Math.max(0, idx - n * 0.1);
    const j0 = Math.floor(back);
    const j1 = Math.min(n, j0 + 1);
    const g = back - j0;
    const c = pts[j0];
    const d = pts[j1];
    if (!c || !d) return;
    const tail = { x: lerp(c.x, d.x, g), y: lerp(c.y, d.y, g) };
    const grad = ctx.createLinearGradient(tail.x, tail.y, head.x, head.y);
    grad.addColorStop(0, rgba(color, 0));
    grad.addColorStop(1, rgba(color, opacity));
    ctx.strokeStyle = grad;
    ctx.lineWidth = 1.4;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(tail.x, tail.y);
    ctx.lineTo(head.x, head.y);
    ctx.stroke();
    glowAt(head.x, head.y, 17, color, 0.38);
    glowAt(head.x, head.y, 5, C.white, 0.7);
  }

  // ── bodies ────────────────────────────────────────────────────────────
  function bodyFaceAlpha(b, pr) {
    if (b.type === 'app') {
      const facing = vdot(b.normal, vnorm(vsub(camState.pos, b.p)));
      return 0.22 + 0.78 * smoothstep(-0.38, 0.36, facing);
    }
    const depthOrigin = project(V(0, 0, 0));
    const far = depthOrigin ? Math.max(0, pr.z - depthOrigin.z) : 0;
    return clamp(1 - far * 0.035, 0.72, 1);
  }

  function applyBodyWarp(b, pr) {
    if (!b.warp) return;
    if (b.warp.sx === 1 && b.warp.sy === 1 && Math.abs(b.warp.rot) < 0.0001) return;
    ctx.translate(pr.x, pr.y);
    ctx.rotate(b.warp.rot);
    ctx.scale(b.warp.sx, b.warp.sy);
    ctx.translate(-pr.x, -pr.y);
  }

  function bodyClipActive(b, pr) {
    if (b.clip == null) return true;
    if (b.clip <= 0.001) return false;
    if (b.clip >= 0.999) return true;
    const ringWorld = b.type === 'app' ? 0.54 : b.radius * 2.7;
    const rPx = ringWorld * pr.s;
    const top = pr.y - rPx * 1.15;
    const h = rPx * 2.3 * b.clip;
    ctx.beginPath();
    ctx.rect(pr.x - rPx * 1.5, top, rPx * 3, h);
    ctx.clip();
    return true;
  }

  function drawRecoilTrail(b, pr, r, color, hot) {
    if (!b.recoilActive) return;
    const ap = project(bodyAnchor(b));
    if (!ap) return;
    const dx = pr.x - ap.x;
    const dy = pr.y - ap.y;
    const dist = Math.hypot(dx, dy);
    if (dist < 1.2) return;
    const len = Math.min(1.8, 0.7 + dist / 22);
    const grad = ctx.createLinearGradient(pr.x - dx * len, pr.y - dy * len, pr.x, pr.y);
    grad.addColorStop(0, rgba(color, 0));
    grad.addColorStop(0.7, rgba(color, 0.18));
    grad.addColorStop(1, rgba(hot, 0.42));
    ctx.strokeStyle = grad;
    ctx.lineWidth = Math.max(1.4, r * 0.55);
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(pr.x - dx * len, pr.y - dy * len);
    ctx.lineTo(pr.x, pr.y);
    ctx.stroke();
  }

  function drawApp(b) {
    const center = bodyVisual(b);
    const pr = project(center);
    if (!pr || !visibleOnScreen(pr, 80)) return;
    const prPad = project(b.p);
    const face = bodyFaceAlpha(b, pr);
    const alpha = clamp01(b.presence) * face;
    if (alpha <= 0.006) return;
    const grow = 0.3 + 0.7 * smoothstep(0, 0.55, b.presence);
    const r = b.radius * grow * pr.s;
    const selected = isFocused(b);
    const hovered = state.hover === b;
    const boost = selected || hovered ? 1.25 : 1;

    ctx.save();
    applyBodyWarp(b, pr);
    if (!bodyClipActive(b, pr)) {
      ctx.restore();
      return;
    }

    // pad ring on the shell
    if (prPad) {
      ctx.globalCompositeOperation = 'lighter';
      const padPts = ringPoints(b.p, b.normal, 0.33 * grow, 48, b.phase + simTime * 0.18);
      strokeWorldPath(padPts, C.app, 0.2 * alpha * boost, 1.0);
      const inner = ringPoints(b.p, b.normal, 0.22 * grow, 36, -simTime * 0.1);
      strokeWorldPath(inner, C.app, 0.08 * alpha, 0.7);
      const tickNorm = b.normal;
      const { t: pt, b: pb } = orthoBasis(tickNorm);
      for (let i = 0; i < 12; i++) {
        const a = (i / 12) * TAU;
        const dir = vadd(vmul(pt, Math.cos(a)), vmul(pb, Math.sin(a)));
        const r0 = 0.34 * grow;
        const r1 = (i % 3 === 0 ? 0.39 : 0.365) * grow;
        line3(vadd(b.p, vmul(dir, r0)), vadd(b.p, vmul(dir, r1)), C.appHot, 0.2 * alpha, 0.8);
      }
      glowWorld(b.p, 0.9 * grow, C.app, 0.12 * alpha);
    }

    // stem
    const stemA = project(b.p);
    if (stemA) {
      const grad = ctx.createLinearGradient(stemA.x, stemA.y, pr.x, pr.y);
      grad.addColorStop(0, rgba(C.appDeep, 0.1 * alpha));
      grad.addColorStop(0.55, rgba(C.app, 0.32 * alpha));
      grad.addColorStop(1, rgba(C.appHot, 0.5 * alpha));
      ctx.strokeStyle = grad;
      ctx.lineWidth = 1.15;
      ctx.beginPath();
      ctx.moveTo(stemA.x, stemA.y);
      ctx.lineTo(pr.x, pr.y);
      ctx.stroke();
    }

    ctx.globalCompositeOperation = 'lighter';
    // halos
    glowAt(pr.x, pr.y, Math.max(6, r * 9.5), C.app, 0.13 * alpha * boost);
    glowAt(pr.x, pr.y, Math.max(4, r * 4.6), C.appHot, 0.12 * alpha);
    if (b.flash < 1) {
      const ft = clamp01(b.flash / 0.34);
      glowAt(pr.x, pr.y, Math.max(4, r * (8 + ft * 12)), C.appHot, Math.pow(1 - ft, 2) * 0.55 * alpha);
    }

    // three gyro rings around the orb
    for (let i = 0; i < 3; i++) {
      const rot = b.phase + simTime * (0.25 + i * 0.12) + i * 0.82;
      const rx = r * (3.4 + i * 0.45);
      const ry = rx * (0.32 + i * 0.12 + Math.sin(rot * 0.6) * 0.04);
      ctx.strokeStyle = rgba(i === 1 ? C.appHot : C.app, (0.2 + i * 0.025) * alpha * boost);
      ctx.lineWidth = i === 1 ? 1.05 : 0.8;
      ctx.beginPath();
      ctx.ellipse(pr.x, pr.y, rx, ry, rot, 0, TAU);
      ctx.stroke();
      const headA = rot + 1.2 + simTime * (0.4 + i * 0.08);
      const hx = pr.x + Math.cos(headA) * rx * Math.cos(rot) - Math.sin(headA) * ry * Math.sin(rot);
      const hy = pr.y + Math.cos(headA) * rx * Math.sin(rot) + Math.sin(headA) * ry * Math.cos(rot);
      glowAt(hx, hy, 4.4, C.appHot, 0.55 * alpha);
    }

    // a few orbiting motes
    for (let i = 0; i < 5; i++) {
      const a = b.phase + simTime * (0.4 + i * 0.11) + i * 1.3;
      const rr = r * (4.1 + i * 0.25);
      const x = pr.x + Math.cos(a) * rr;
      const y = pr.y + Math.sin(a * 1.7) * rr * 0.35;
      ctx.fillStyle = rgba(i % 2 ? C.appHot : C.app, 0.32 * alpha);
      ctx.beginPath();
      ctx.arc(x, y, 1.1, 0, TAU);
      ctx.fill();
    }

    // orb
    drawSphere(pr.x, pr.y, Math.max(1.6, r), C.app, C.appHot, C.appDeep, alpha * 0.96, boost);
    ctx.globalCompositeOperation = 'lighter';
    drawRecoilTrail(b, pr, r, C.app, C.appHot);
    if (selected || hovered) {
      ctx.strokeStyle = rgba(C.appHot, 0.5);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(pr.x, pr.y, r + 4.5, 0, TAU);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawDomain(b) {
    const center = bodyVisual(b);
    const pr = project(center);
    if (!pr || !visibleOnScreen(pr, 90)) return;
    const face = bodyFaceAlpha(b, pr);
    const alpha = clamp01(b.presence) * face;
    if (alpha <= 0.006) return;
    const grow = 0.3 + 0.7 * smoothstep(0, 0.55, b.presence);
    const r = b.radius * grow * pr.s;
    const selected = isFocused(b);
    const hovered = state.hover === b;
    const boost = selected || hovered ? 1.22 : 1;

    ctx.save();
    applyBodyWarp(b, pr);
    if (!bodyClipActive(b, pr)) {
      ctx.restore();
      return;
    }

    ctx.globalCompositeOperation = 'lighter';
    // atmospheric halo
    glowAt(pr.x, pr.y, Math.max(8, r * 8.4), C.dest, 0.14 * alpha * boost);
    glowAt(pr.x, pr.y, Math.max(5, r * 3.8), C.destHot, 0.1 * alpha);

    // world orbit, slowly turning
    const orbitSpin = simTime * 0.13 + b.phase;
    const orbitNormal = vnorm(rotateY(V(0.25 + Math.sin(b.phase) * 0.15, 0.94, 0.2 + Math.cos(b.phase) * 0.12), orbitSpin * 0.6));
    const orbit = ringPoints(center, orbitNormal, b.radius * 1.98 * grow, 72, orbitSpin);
    strokeWorldPath(orbit, C.dest, 0.13 * alpha, 0.7);
    strokeWorldPath(orbit, C.destDeep, 0.08 * alpha, 2.4);
    const arcStart = orbitSpin + 0.7;
    const arcPts = [];
    for (let i = 0; i <= 28; i++) arcPts.push(ringPoint(center, orbitNormal, b.radius * 1.98 * grow, arcStart + i * 0.055));
    strokeWorldPath(arcPts, C.destHot, 0.55 * alpha, 1.15);
    const tip = arcPts[arcPts.length - 1];
    const tipPr = project(tip);
    if (tipPr) glowAt(tipPr.x, tipPr.y, 14, C.destHot, 0.46 * alpha);

    // camera-facing instrument ring with a bright arc
    const camNormal = vnorm(vsub(camState.pos, center));
    const start = simTime * 0.4 + 1.7 + b.phase;
    ctx.strokeStyle = rgba(C.dest, 0.16 * alpha);
    ctx.lineWidth = 0.9;
    ctx.beginPath();
    ctx.arc(pr.x, pr.y, r * 2.08, 0, TAU);
    ctx.stroke();
    const arcR = r * 2.1;
    ctx.strokeStyle = rgba(C.destHot, 0.75 * alpha);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(pr.x, pr.y, arcR, start, start + 1.08);
    ctx.stroke();
    const hx = pr.x + Math.cos(start + 1.08) * arcR;
    const hy = pr.y + Math.sin(start + 1.08) * arcR;
    glowAt(hx, hy, 7, C.destHot, 0.7 * alpha);
    // small tick marks on the ring
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * TAU + simTime * 0.08;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      ctx.strokeStyle = rgba(C.dest, 0.18 * alpha);
      ctx.lineWidth = 0.7;
      ctx.beginPath();
      ctx.moveTo(pr.x + ca * arcR * 1.03, pr.y + sa * arcR * 1.03);
      ctx.lineTo(pr.x + ca * arcR * 1.09, pr.y + sa * arcR * 1.09);
      ctx.stroke();
    }

    // two planet-like orbiters
    for (let i = 0; i < 2; i++) {
      const a = simTime * (0.55 + i * 0.14) + b.phase + i * 2.4;
      const rr = r * (2.5 + i * 0.42);
      const ox = pr.x + Math.cos(a) * rr;
      const oy = pr.y + Math.sin(a * 1.6) * rr * 0.4;
      glowAt(ox, oy, 10, i === 0 ? C.destHot : C.violet, 0.4 * alpha);
      ctx.fillStyle = rgba(C.white, 0.7 * alpha);
      ctx.beginPath();
      ctx.arc(ox, oy, 1.2, 0, TAU);
      ctx.fill();
    }

    if (b.flash < 1) {
      const ft = clamp01(b.flash / 0.34);
      glowAt(pr.x, pr.y, Math.max(4, r * (7 + ft * 13)), C.destHot, Math.pow(1 - ft, 2.2) * 0.8 * alpha);
    }

    // orb
    drawSphere(pr.x, pr.y, Math.max(1.8, r), C.dest, C.destHot, C.destDeep, alpha * 0.94, boost);
    ctx.globalCompositeOperation = 'lighter';
    // local-ish heartbeat for the nearest bodies; subtle
    const beat = 0.5 + 0.5 * Math.sin(simTime * 2.1 + b.phase);
    glowAt(pr.x, pr.y, Math.max(6, r * (4.7 + beat * 1.2)), C.dest, 0.07 * alpha * (0.6 + beat * 0.4));
    drawRecoilTrail(b, pr, r, C.dest, C.destHot);
    if (selected || hovered) {
      ctx.strokeStyle = rgba(C.destHot, 0.5);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(pr.x, pr.y, r + 5.5, 0, TAU);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawSphere(x, y, r, color, hot, deep, alpha, boost) {
    if (r < 0.6) return;
    ctx.globalCompositeOperation = 'source-over';
    const grad = ctx.createRadialGradient(x - r * 0.3, y - r * 0.34, r * 0.04, x, y, r * 1.05);
    grad.addColorStop(0, rgba(C.white, alpha * 0.96));
    grad.addColorStop(0.16, rgba(hot, alpha * 0.98));
    grad.addColorStop(0.48, rgba(color, alpha * 0.96));
    grad.addColorStop(0.87, rgba(deep, alpha * 0.92));
    grad.addColorStop(1, rgba(deep, alpha * 0.32));
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, TAU);
    ctx.fill();
    // hot glint
    ctx.fillStyle = rgba(C.white, alpha * 0.75 * boost);
    ctx.beginPath();
    ctx.arc(x - r * 0.27, y - r * 0.32, Math.max(0.6, r * 0.18), 0, TAU);
    ctx.fill();
    ctx.globalCompositeOperation = 'lighter';
  }

  function drawBodies() {
    const sorted = bodies
      .map((b) => ({ b, pr: project(bodyVisual(b)) }))
      .filter((e) => e.pr)
      .sort((a, b) => b.pr.z - a.pr.z);
    for (const e of sorted) {
      if (e.b.presence <= 0.004) continue;
      if (e.b.type === 'app') drawApp(e.b);
      else drawDomain(e.b);
    }
  }

  // ── labels + targets ──────────────────────────────────────────────────
  const labelBoxes = [];
  function labelAlpha(b) {
    if (b.presence <= 0.01) return 0;
    let a = 0.38 * clamp01(b.presence);
    if (b.clip != null) a *= clamp01(b.clip);
    if (isFocused(b) || state.hover === b) a = 0.94 * clamp01(b.presence);
    return a;
  }

  function drawLabels() {
    labelBoxes.length = 0;
    const centerPr = project(V(0, 0, 0));
    const entries = bodies
      .map((b) => ({ b, pr: project(bodyVisual(b)) }))
      .filter((e) => e.pr && visibleOnScreen(e.pr, 80))
      .sort((a, b) => {
        const af = isFocused(a.b) || state.hover === a.b ? 1 : 0;
        const bf = isFocused(b.b) || state.hover === b.b ? 1 : 0;
        return bf - af;
      });

    ctx.globalCompositeOperation = 'source-over';
    for (const { b, pr } of entries) {
      const baseAlpha = labelAlpha(b);
      if (baseAlpha < 0.02) continue;
      const focused = isFocused(b) || state.hover === b;
      const font = focused ? '500 10px ' + '"SF Mono", ui-monospace, Menlo, monospace' : '400 9px ' + '"SF Mono", ui-monospace, Menlo, monospace';
      ctx.font = font;
      const text = b.short;
      const metrics = ctx.measureText(text);
      const w = metrics.width;
      const h = 12;
      const bodyR = b.type === 'app' ? Math.max(16, 0.55 * pr.s) : Math.max(15, b.radius * 2.8 * pr.s);
      const away = centerPr ? { x: pr.x - centerPr.x, y: pr.y - centerPr.y } : { x: 0, y: -1 };
      const awayLen = Math.hypot(away.x, away.y);
      const dir = awayLen > 18 ? { x: away.x / awayLen, y: away.y / awayLen } : b.type === 'app' ? { x: 0, y: -1 } : { x: 0, y: 1 };
      const off = bodyR + 12;
      let x = pr.x + dir.x * off;
      let y = pr.y + dir.y * off;
      let align = dir.x < -0.25 ? 'right' : dir.x > 0.25 ? 'left' : 'center';
      let box = {
        x: align === 'center' ? x - w / 2 : align === 'right' ? x - w : x,
        y: y - h / 2,
        w,
        h,
      };
      const tries = [
        [0, 0], [0, 12], [0, -12], [0, 24], [0, -24], [dir.x > 0 ? 10 : -10, 0],
      ];
      let placed = false;
      for (const [dx, dy] of tries) {
        const bx = box.x + dx;
        const by = box.y + dy;
        if (bx < 8 || bx + w > view.w - 8 || by < 70 || by + h > view.h - 120) continue;
        const rect = { x: bx - 3, y: by - 2, w: w + 6, h: h + 4 };
        if (labelBoxes.some((r) => !(rect.x + rect.w < r.x || rect.x > r.x + r.w || rect.y + rect.h < r.y || rect.y > r.y + r.h))) {
          if (!focused) continue;
        }
        x += dx;
        y += dy;
        box = { x: bx, y: by, w, h };
        labelBoxes.push(rect);
        placed = true;
        break;
      }
      if (!placed && !focused) continue;

      // leader dot + text
      const dotColor = b.type === 'app' ? C.app : C.dest;
      const dotX = align === 'left' ? box.x - 6 : align === 'right' ? box.x + w + 6 : box.x - 7;
      const dotY = y;
      const dotAlpha = baseAlpha * (focused ? 1 : 0.8);
      ctx.fillStyle = rgba(dotColor, dotAlpha);
      ctx.beginPath();
      ctx.arc(dotX, dotY, focused ? 1.7 : 1.2, 0, TAU);
      ctx.fill();
      if (focused) {
        ctx.strokeStyle = rgba(dotColor, 0.3);
        ctx.lineWidth = 0.6;
        ctx.beginPath();
        ctx.arc(dotX, dotY, 4.2, 0, TAU);
        ctx.stroke();
      }
      ctx.fillStyle = rgba(focused ? C.white : b.type === 'app' ? C.appHot : C.destHot, baseAlpha);
      ctx.textAlign = align;
      ctx.textBaseline = 'middle';
      if (focused) {
        ctx.shadowColor = 'rgba(2,7,10,0.9)';
        ctx.shadowBlur = 3;
      }
      ctx.fillText(text, x, y + 0.5);
      ctx.shadowBlur = 0;
      ctx.textAlign = 'left';
      ctx.textBaseline = 'alphabetic';
    }
  }

  function isFocused(b) {
    if (state.target === 'both') {
      return (b.type === 'app' && b.index === state.focusApp) || (b.type === 'domain' && b.index === state.focusDomain);
    }
    if (state.target === 'app') return b.type === 'app' && b.index === state.focusApp;
    return b.type === 'domain' && b.index === state.focusDomain;
  }

  function drawTargetBrackets() {
    ctx.globalCompositeOperation = 'lighter';
    for (const b of bodies) {
      if (!isFocused(b)) continue;
      const pr = project(bodyVisual(b));
      if (!pr || b.presence < 0.02) continue;
      const ring = b.type === 'app' ? Math.max(22, 0.58 * pr.s) : Math.max(19, b.radius * 2.8 * pr.s);
      const rr = ring + 8;
      const len = 6;
      const color = b.type === 'app' ? C.appHot : C.destHot;
      const alpha = (0.55 + 0.12 * Math.sin(simTime * 2.4 + b.phase)) * (0.3 + 0.7 * clamp01(b.presence));
      ctx.strokeStyle = rgba(color, alpha);
      ctx.lineWidth = 1;
      for (let i = 0; i < 4; i++) {
        const sx = i === 0 || i === 3 ? -1 : 1;
        const sy = i === 0 || i === 1 ? -1 : 1;
        ctx.beginPath();
        ctx.moveTo(pr.x + sx * rr, pr.y + sy * rr - sy * len);
        ctx.lineTo(pr.x + sx * rr, pr.y + sy * rr);
        ctx.lineTo(pr.x + sx * rr - sx * len, pr.y + sy * rr);
        ctx.stroke();
      }
    }
    if (state.hover && !isFocused(state.hover)) {
      const pr = project(bodyVisual(state.hover));
      if (pr) {
        ctx.strokeStyle = rgba(C.ice, 0.5);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(pr.x, pr.y, state.hover.type === 'app' ? 20 : Math.max(18, state.hover.radius * 2.9 * pr.s), 0, TAU);
        ctx.stroke();
      }
    }
  }

  // ── motion studies ────────────────────────────────────────────────────
  function bodyFxRadius(b) {
    return b.type === 'app' ? 0.38 : Math.max(0.3, b.radius * 2.2);
  }

  function envOrigin(b) {
    return bodyAnchor(b);
  }

  function bodyFxNormal(b) {
    const toCam = vnorm(vsub(camState.pos, bodyAnchor(b)));
    const bias = b.type === 'app' ? b.normal : V(0, 1, 0);
    return vnorm(vadd(toCam, vmul(bias, 0.28)));
  }

  function drawConvergeMotes(motes, age, env, collapse, spin, opts = {}) {
    const { t, b } = orthoBasis(env.normal);
    const p = clamp01(age / collapse);
    const q = easeInCubic(p);
    for (const m of motes) {
      const a = age - m.delay;
      if (a < 0) continue;
      const rr = m.radius * (1 - q * (opts.keep == null ? 0.985 : opts.keep));
      const ang = m.angle + m.spin * p * (opts.spinScale == null ? 2.6 : opts.spinScale) + spin;
      const pos = vadd(
        env.center,
        vadd(
          vadd(vmul(t, Math.cos(ang) * rr), vmul(b, Math.sin(ang) * rr)),
          vmul(env.normal, m.normal * (1 - q * 0.9))
        )
      );
      const pr = project(pos);
      if (!pr) continue;
      const alpha = Math.pow(1 - p, 0.5) * clamp01(a / 0.03) * (opts.opacity == null ? 0.7 : opts.opacity);
      if (alpha <= 0.004) continue;
      if (opts.streaks) {
        const backAng = m.angle + m.spin * Math.max(0, p - 0.035) * 2.6 + spin;
        const backR = m.radius * (1 - easeInCubic(Math.max(0, p - 0.035)) * 0.985);
        const backPos = vadd(
          env.center,
          vadd(
            vadd(vmul(t, Math.cos(backAng) * backR), vmul(b, Math.sin(backAng) * backR)),
            vmul(env.normal, m.normal * (1 - easeInCubic(Math.max(0, p - 0.035)) * 0.9))
          )
        );
        const bp = project(backPos);
        if (bp) {
          ctx.strokeStyle = rgba(m.color, alpha * 0.55);
          ctx.lineWidth = Math.max(0.6, m.size * pr.s * 1.2);
          ctx.beginPath();
          ctx.moveTo(bp.x, bp.y);
          ctx.lineTo(pr.x, pr.y);
          ctx.stroke();
        }
      }
      ctx.fillStyle = rgba(m.color, alpha);
      const size = Math.max(0.9, m.size * pr.s * 1.4);
      ctx.beginPath();
      ctx.arc(pr.x, pr.y, size, 0, TAU);
      ctx.fill();
      if (opts.glint && m.size > 0.025) glowAt(pr.x, pr.y, 12, m.color, alpha * 0.35);
    }
  }

  function drawSeedTrail(start, end, t, basis, r, color, alpha) {
    for (let i = 0; i < 12; i++) {
      const u = clamp01(t - i * 0.03);
      const p = vadd(
        vlerp(start, end, u * u),
        vadd(vmul(basis.t, Math.sin(u * 9) * r * 0.1 * (1 - u)), vmul(basis.b, Math.cos(u * 6) * r * 0.03 * (1 - u)))
      );
      const pr = project(p);
      if (!pr) continue;
      const a = alpha * (1 - i / 12) * clamp01(t / 0.1);
      if (a <= 0.004) continue;
      ctx.fillStyle = rgba(color, a);
      ctx.beginPath();
      ctx.arc(pr.x, pr.y, Math.max(0.7, (1 - i / 12) * r * 0.055 * pr.s), 0, TAU);
      ctx.fill();
    }
  }

  const STUDIES = {
    impact: [
      {
        id: 'nova',
        name: 'Nova Lance',
        tagline: 'Razor ring · violet afterimage',
        duration: 1.12,
        flight: 0.24,
        recoil: 1.15,
        recoilLabel: 'strong',
        shake: 3.2,
        look: 'A white-hot needle punches along the arrival tangent, then a razor ring tears open. The body is knocked outward and recovers without a second bounce.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const sparks = makeSparks(rng, 36, r, {
            colors: [C.white, C.ice, C.violet, C.host],
            speed: [1.8, 5.4], tangential: 1.8, normalSpeed: 1.2, drag: 1.28,
            life: [0.3, 0.85], size: [0.012, 0.042], start: 0.26, delay: [0, 0.04],
          });
          const seed = rng() * 9;
          return {
            draw(env) {
              const age = env.age;
              drawFlash(env, { duration: 0.48, size: 3.8, color: C.white, halo: C.violet, opacity: 0.92 });
              drawShock(env, {
                start: 1.12, end: 4.25, duration: 0.92,
                core: C.ice, tail: C.violet, thickness: 0.045, rays: 28, seed, opacity: 0.92,
              });
              drawShock(env, {
                start: 0.92, end: 2.95, duration: 0.95, delay: 0.055,
                core: C.host, tail: C.hostDeep, thickness: 0.021, rays: 0, seed: seed + 2, opacity: 0.52,
              });
              drawShock(env, {
                start: 1.0, end: 3.5, duration: 0.48,
                core: C.white, tail: C.host, thickness: 0.011, rays: 44, seed: seed + 5, opacity: 0.55,
              });
              const lance = easeOutCubic(clamp01(age / 0.38));
              const a = vadd(env.center, vmul(normal, -r * 0.16));
              const b = vadd(env.center, vmul(normal, r * (0.2 + lance * 3.2)));
              const pa = project(a);
              const pb = project(b);
              if (pa && pb && age < 0.6) {
                const fade = Math.pow(1 - clamp01(age / 0.6), 1.4);
                const grad = ctx.createLinearGradient(pa.x, pa.y, pb.x, pb.y);
                grad.addColorStop(0, rgba(C.host, 0));
                grad.addColorStop(0.35, rgba(C.ice, 0.75 * fade));
                grad.addColorStop(1, rgba(C.white, 0.95 * fade));
                ctx.strokeStyle = grad;
                ctx.lineWidth = 1.5 + (1 - lance) * 2.2;
                ctx.beginPath();
                ctx.moveTo(pa.x, pa.y);
                ctx.lineTo(pb.x, pb.y);
                ctx.stroke();
                glowAt(pb.x, pb.y, 22 * (0.4 + lance), C.violetHot, 0.68 * fade);
                glowAt(pb.x, pb.y, 7, C.white, 0.9 * fade);
              }
              drawSparks(sparks, age, env, 0.9);
              // a short retro-foil behind the blast
              if (age < 0.55) {
                const head = easeOutCubic(clamp01(age / 0.4));
                const tailA = vadd(env.center, vmul(normal, -r * 4.6 * (1 - head)));
                const tailB = vadd(tailA, vmul(normal, -r * 0.3));
                line3(tailA, tailB, C.violetHot, Math.pow(1 - head, 1.6) * 0.45, 1.1);
              }
            },
          };
        },
      },
      {
        id: 'ember',
        name: 'Cold Ember',
        tagline: 'Sparse cinders · long afterglow',
        duration: 1.88,
        flight: 0.24,
        recoil: 0.86,
        recoilLabel: 'soft',
        shake: 2.0,
        look: 'The same hit with a longer, quieter tail: icy cinders scatter and settle while the ring keeps drifting. Use this when the globe is calm and the blast should not steal the scene.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const sparks = makeSparks(rng, 96, r, {
            colors: [C.ice, C.host, C.violet, C.white, C.hostDim],
            speed: [1.2, 4.5], tangential: 1.3, normalSpeed: 0.8, drag: 0.62,
            life: [0.8, 1.75], size: [0.012, 0.044], start: 0.22, delay: [0, 0.08],
          });
          const cinders = makeSparks(rng, 26, r, {
            colors: [C.white, C.ice, C.violet, C.host],
            speed: [2.2, 4.8], tangential: 0.8, normalSpeed: 0.9, drag: 0.32,
            life: [1.0, 1.75], size: [0.04, 0.09], start: 0.3, delay: [0, 0.05],
          });
          const embers = [];
          for (let i = 0; i < 28; i++) {
            embers.push({
              angle: rng() * TAU,
              start: (0.2 + rng() * 0.8) * r,
              speed: (0.8 + rng() * 2.8) * r,
              drag: 0.3 + rng() * 0.3,
              drift: (rng() * 2 - 1) * 0.8 * r,
              size: (0.055 + rng() * 0.12) * r,
              life: 0.8 + rng() * 0.8,
              color: rng() > 0.65 ? C.violet : rng() > 0.35 ? C.ice : C.host,
            });
          }
          const haze = [];
          for (let i = 0; i < 30; i++) {
            haze.push({
              angle: rng() * TAU, start: rng() * r * 0.9,
              speed: (0.2 + rng() * 1.3) * r, drift: (rng() * 2 - 1) * 0.8 * r,
              size: (0.09 + rng() * 0.2) * r, life: 0.9 + rng() * 0.8,
              color: rng() > 0.5 ? C.ice : C.violet,
            });
          }
          const seed = rng() * 9;
          return {
            draw(env) {
              const age = env.age;
              const t = clamp01(age / env.study.duration);
              drawFlash(env, { duration: 0.74, size: 4.6, color: C.white, halo: C.host, opacity: 0.82 });
              drawFlash(env, { delay: 0.12, duration: 0.5, size: 2.8, color: C.ice, halo: C.violet, opacity: 0.42 });
              drawShock(env, {
                start: 0.9, end: 4.2, duration: 1.55,
                core: C.white, tail: C.host, thickness: 0.095, rays: 24, seed, opacity: 0.85,
              });
              drawShock(env, {
                start: 0.7, end: 3.2, duration: 1.22, delay: 0.08,
                core: C.host, tail: C.hostDeep, thickness: 0.065, rays: 0, seed: seed + 3, opacity: 0.7,
              });
              drawShock(env, {
                start: 1.0, end: 2.6, duration: 0.8, delay: 0.28,
                core: C.violetHot, tail: C.violet, thickness: 0.028, rays: 0, seed: seed + 7, opacity: 0.55,
              });
              drawShock(env, {
                start: 0.5, end: 1.8, duration: 0.62,
                core: C.white, tail: C.host, thickness: 0.018, rays: 0, seed: seed + 5, opacity: 0.6,
              });
              // cold haze drifting with the sparks
              const { t: bt, b: bb } = orthoBasis(normal);
              for (const h of haze) {
                const a = age - 0.02;
                if (a < 0 || a > h.life) continue;
                const travel = (1 - Math.exp(-0.5 * a)) / 0.5;
                const dir = vadd(vmul(bt, Math.cos(h.angle)), vmul(bb, Math.sin(h.angle)));
                const pos = vadd(
                  vadd(env.center, vadd(vmul(dir, h.start + h.speed * travel), vmul(normal, h.drift * a))),
                  V(0, a * 0.12 * r, 0)
                );
                const pr = project(pos);
                if (!pr) continue;
                const alpha = Math.pow(1 - a / h.life, 1.3) * 0.1;
                glowAt(pr.x, pr.y, Math.max(3, h.size * pr.s), h.color, alpha);
              }
              drawSparks(sparks, age, env, 1);
              drawSparks(cinders, age, env, 1);
              // slower, larger embers give the cold explosion a body
              const { t: ebT, b: ebB } = orthoBasis(normal);
              for (const em of embers) {
                const a = age - 0.04;
                if (a < 0 || a > em.life) continue;
                const travel = (1 - Math.exp(-em.drag * a)) / em.drag;
                const dir = vadd(vmul(ebT, Math.cos(em.angle)), vmul(ebB, Math.sin(em.angle)));
                const pos = vadd(env.center, vadd(vmul(dir, em.start + em.speed * travel), vmul(normal, em.drift * a)));
                const pr = project(pos);
                if (!pr) continue;
                const alpha = Math.pow(1 - a / em.life, 1.2) * 0.46;
                glowAt(pr.x, pr.y, Math.max(5, em.size * pr.s * 1.2), em.color, alpha);
                ctx.fillStyle = rgba(C.white, alpha * 0.55);
                ctx.beginPath();
                ctx.arc(pr.x, pr.y, Math.max(0.7, em.size * pr.s * 0.14), 0, TAU);
                ctx.fill();
              }
              drawGlowAtCenter(env, env.r * (2.6 + easeOutCubic(t) * 5.4), C.host, Math.pow(1 - t, 1.1) * 0.27);
              drawGlowAtCenter(env, env.r * 1.35, C.ice, Math.pow(1 - t, 2.1) * 0.4);
              // big slow cinders read as a cloud, not noise
              for (let i = 0; i < 9; i++) {
                const h = hash01(seed * 31 + i * 17);
                const dirA = h * TAU;
                const rr = env.r * (0.4 + ((i * 0.117 + 0.1) % 0.6));
                const a = age - 0.05;
                if (a < 0) continue;
                const { t: bt, b: bb } = orthoBasis(normal);
                const pos = vadd(env.center, vadd(vmul(bt, Math.cos(dirA) * (rr + a * env.r * 0.7)), vmul(bb, Math.sin(dirA) * (rr + a * env.r * 0.7))));
                const pr = project(pos);
                if (pr) glowAt(pr.x, pr.y, Math.max(8, env.r * pr.s * 1.4), i % 2 ? C.violet : C.ice, Math.pow(1 - a / 1.5, 1.2) * 0.52);
              }
            },
          };
        },
      },
      {
        id: 'prism',
        name: 'Prism Fracture',
        tagline: 'Shard debris · chromatic echo',
        duration: 1.3,
        flight: 0.24,
        recoil: 1.25,
        recoilLabel: 'strong',
        shake: 3.4,
        look: 'The body cracks into chromatic shards before the rings resolve. The echo ring is deliberately off-axis; it is the most graphic, least soft of the blasts.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const { t: bt } = orthoBasis(normal);
          const shards = makeShards(rng, 24, r, {
            colors: [C.ice, C.host, C.violet, C.white, C.hostDim],
            speed: [1.4, 3.8], drift: 0.34, start: 0.62,
            len: [0.28, 0.72], wide: [0.03, 0.11], delay: [0, 0.06],
          });
          const sparks = makeSparks(rng, 42, r, {
            colors: [C.white, C.ice, C.violet, C.host],
            speed: [2.4, 6.0], tangential: 1.4, normalSpeed: 1.3, drag: 0.8,
            life: [0.28, 0.8], size: [0.01, 0.04], start: 0.3, delay: [0, 0.05],
          });
          const seed = rng() * 9;
          const offA = vmul(bt, r * 0.055);
          const offB = vmul(bt, -r * 0.05);
          const cracks = [];
          for (let i = 0; i < 3; i++) {
            cracks.push({ angle: rng() * TAU });
          }
          return {
            draw(env) {
              const age = env.age;
              drawFlash(env, { duration: 0.35, size: 4.2, color: C.white, halo: C.violet, opacity: 0.9 });
              drawFlash(env, { duration: 0.5, delay: 0.03, size: 3.4, color: C.ice, halo: C.host, opacity: 0.5 });
              drawShock(env, {
                start: 1.08, end: 3.8, duration: 0.72,
                core: C.white, tail: C.violet, thickness: 0.02, rays: 40, seed, opacity: 0.78,
              });
              drawShock(env, {
                start: 0.94, end: 3.4, duration: 0.9, delay: 0.05, offset: offA,
                core: C.host, tail: C.hostDeep, thickness: 0.014, rays: 0, seed: seed + 1, opacity: 0.45,
              });
              drawShock(env, {
                start: 0.9, end: 3.0, duration: 0.84, delay: 0.09, offset: offB,
                core: C.violetHot, tail: C.violet, thickness: 0.014, rays: 0, seed: seed + 2, opacity: 0.36,
              });
              if (age < 0.2) {
                const { t: ct, b: cb } = orthoBasis(normal);
                for (let i = 0; i < cracks.length; i++) {
                  const a = cracks[i].angle;
                  const dir = vadd(vmul(ct, Math.cos(a)), vmul(cb, Math.sin(a)));
                  line3(vadd(env.center, vmul(dir, -r * 1.25)), vadd(env.center, vmul(dir, r * 1.25)), C.white, (1 - age / 0.2) * 0.55, 1.2);
                }
              }
              drawSparks(sparks, age, env, 0.9);
              drawShards(shards, age, env, 0.92);
            },
          };
        },
      },
      {
        id: 'hammer',
        name: 'Hammerfall',
        tagline: 'Pre-crack · heavy shockwave',
        duration: 1.55,
        flight: 0.24,
        recoil: 1.5,
        recoilLabel: 'heaviest',
        shake: 5.2,
        look: 'A fast inward compression sells the hit before the release, then a heavy ring crosses the whole globe. The largest recoil of the four, and the only one that moves the camera note in the room.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const sparks = makeSparks(rng, 66, r, {
            colors: [C.white, C.ice, C.host, C.violet],
            speed: [1.6, 6.2], tangential: 2.2, normalSpeed: 1.5, drag: 0.9,
            life: [0.35, 1.15], size: [0.012, 0.05], start: 0.26, delay: [0.16, 0.22],
          });
          const dust = makeSparks(rng, 30, r, {
            colors: [C.ice, C.violet, C.hostDim],
            speed: [0.7, 2.2], tangential: 1.1, normalSpeed: 0.6, drag: 0.25,
            life: [1.0, 1.6], size: [0.024, 0.07], start: 0.9, delay: [0.16, 0.25],
          });
          const shards = makeShards(rng, 10, r, {
            colors: [C.ice, C.white, C.violet], speed: [0.8, 2.4], drift: 0.4,
            start: 0.4, len: [0.3, 0.65], wide: [0.04, 0.1], delay: [0.16, 0.23],
          });
          const seed = rng() * 9;
          return {
            draw(env) {
              const age = env.age;
              // inward pre-crack
              if (age < 0.2) {
                drawShock(env, {
                  start: 2.7, end: 0.22, duration: 0.18,
                  core: C.ice, tail: C.violet, thickness: 0.028, rays: 0, seed: seed + 2, opacity: 0.9,
                });
                drawGlowAtCenter(env, env.r * (0.6 + age * 7), C.host, 0.16 + age * 2);
              }
              drawFlash(env, { duration: 0.52, delay: 0.16, size: 5.2, color: C.white, halo: C.violet, opacity: 0.95 });
              drawShock(env, {
                start: 0.35, end: 5.5, duration: 1.08, delay: 0.16,
                core: C.ice, tail: C.violet, thickness: 0.062, rays: 18, seed, opacity: 0.95,
              });
              drawShock(env, {
                start: 0.55, end: 3.8, duration: 0.92, delay: 0.22,
                core: C.white, tail: C.host, thickness: 0.022, rays: 0, seed: seed + 3, opacity: 0.5,
              });
              drawShock(env, {
                start: 0.8, end: 2.4, duration: 0.55, delay: 0.16,
                core: C.host, tail: C.hostDeep, thickness: 0.03, rays: 0, seed: seed + 4, opacity: 0.55,
              });
              drawSparks(sparks, age, env, 0.95);
              drawSparks(dust, age, env, 0.55);
              drawShards(shards, age, env, 0.85);
              // brief screen-space pressure line at the body silhouette
              if (age > 0.16 && age < 0.42) {
                drawGlowAtCenter(env, env.r * 4.8, C.violet, (1 - (age - 0.16) / 0.26) * 0.1);
              }
            },
          };
        },
      },
    ],
    appear: [
      {
        id: 'condense',
        name: 'Condense',
        tagline: 'Motes spiral in · body snaps',
        duration: 1.45,
        look: 'Forty-eight motes wind inward on a short spiral and compress into a single bright point. The body snaps out of the compression with a tiny overshoot. Fastest read, most physical.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const motes = makeMotes(rng, 48, r, {
            radius: [2.3, 3.5], spin: 1.2, normal: 1.0,
            size: [0.009, 0.034], delay: 0.0,
            colors: [C.appHot, C.host, C.ice, C.violet, C.white],
          });
          const sparks = makeSparks(rng, 20, r, {
            colors: [C.appHot, C.host, C.white, C.violet],
            speed: [0.8, 2.8], tangential: 1.8, normalSpeed: 1.0, drag: 1.1,
            life: [0.3, 0.8], size: [0.008, 0.032], start: 0.45, delay: [0.5, 0.57],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.5) return 0;
              const t = clamp01((age - 0.5) / 0.27);
              let v = easeOutBack(t, 1.28);
              if (age > 0.5 && age < 0.73) v *= 0.72 + 0.28 * Math.abs(Math.sin(age * 88));
              return clamp(v, 0, 1.06);
            },
            draw(env) {
              const age = env.age;
              const collapse = clamp01(age / 0.55);
              const shrink = 1 - easeInCubic(collapse);
              const { t, b } = orthoBasis(normal);
              // three spiral arms
              if (age < 0.64) {
                for (let arm = 0; arm < 3; arm++) {
                  const base = (arm / 3) * TAU + age * 1.35;
                  const pts = [];
                  for (let j = 0; j <= 40; j++) {
                    const u = j / 40;
                    const ang = base + u * 4.2;
                    const rr = r * (0.06 + 2.9 * (1 - u)) * shrink;
                    pts.push(
                      vadd(
                        env.center,
                        vadd(
                          vadd(vmul(t, Math.cos(ang) * rr), vmul(b, Math.sin(ang) * rr)),
                          vmul(normal, Math.sin(u * 9 + arm * 2) * r * 0.07 * shrink)
                        )
                      )
                    );
                  }
                  const fade = (1 - smoothstep(0.36, 0.62, age)) * (0.3 - arm * 0.04);
                  strokeWorldPath(pts, arm === 1 ? C.host : C.appHot, Math.max(0, fade), 0.7);
                }
              }
              drawConvergeMotes(motes, age, env, 0.56, age * 1.2, { opacity: 0.72, streaks: true, glint: true });
              const build = clamp01(age / 0.5);
              drawGlowAtCenter(env, r * (0.5 + build * 1.9), C.host, 0.12 * build * (1 - smoothstep(0.55, 0.8, age) * 0.8));
              drawFlash(env, { delay: 0.5, duration: 0.42, size: 2.9, color: C.white, halo: C.app, opacity: 0.8 });
              drawShock(env, {
                start: 0.8, end: 2.65, duration: 0.8, delay: 0.5,
                core: C.appHot, tail: C.host, thickness: 0.033, rays: 14, seed, opacity: 0.55,
              });
              drawSparks(sparks, age, env, 0.72);
            },
          };
        },
      },
      {
        id: 'weave',
        name: 'Weave',
        tagline: 'Tendrils stitch a core',
        duration: 1.78,
        look: 'Six jagged tendrils arrive from different directions and stitch the core shut. The body flickers in at the weld, like the instrument has to settle before it can be trusted. Most deliberate read.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const tendrils = [];
          const center = envOrigin(body);
          const toCam = vnorm(vsub(camState.pos, center));
          const camBasis = orthoBasis(toCam);
          for (let i = 0; i < 6; i++) {
            const ang = (i / 6) * TAU + (rng() - 0.5) * 0.22;
            const radial = vadd(vmul(camBasis.t, Math.cos(ang)), vmul(camBasis.b, Math.sin(ang)));
            const origin = vadd(
              center,
              vadd(vmul(radial, r * (2.25 + rng() * 0.65)), vmul(toCam, (rng() - 0.5) * r * 0.24))
            );
            const dir = vnorm(vsub(origin, center));
            const basis = orthoBasis(dir);
            tendrils.push({
              origin, dir, basis, seed: rng() * 100,
              start: i * 0.032 + rng() * 0.03,
              duration: 0.4 + rng() * 0.08,
              color: i === 2 ? C.host : i % 2 ? C.appHot : C.ice,
            });
          }
          const sparks = makeSparks(rng, 34, r, {
            colors: [C.appHot, C.ice, C.host, C.white, C.violet],
            speed: [1.2, 4.6], tangential: 2.2, normalSpeed: 1.4, drag: 1.1,
            life: [0.32, 0.9], size: [0.01, 0.04], start: 0.3, delay: [0.57, 0.64],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.58) return 0;
              const t = clamp01((age - 0.58) / 0.26);
              let v = easeOutBack(t, 1.3);
              if (age < 0.76) v *= 0.55 + 0.45 * Math.sin(age * 90);
              return clamp(v, 0, 1.05);
            },
            draw(env) {
              const age = env.age;
              const center = env.center;
              for (const td of tendrils) {
                const raw = clamp01((age - td.start) / td.duration);
                if (raw <= 0) continue;
                const reach = easeInOutCubic(raw);
                const pts = [];
                for (let j = 0; j <= 26; j++) {
                  const f = j / 26;
                  const base = vlerp(td.origin, center, reach * f);
                  const amp = r * 0.72 * (1 - reach * 0.55) * (0.35 + f * 0.9);
                  const wobble = Math.sin(f * 16 + td.seed + age * 18) * amp + Math.cos(f * 29 - age * 12 + td.seed * 0.7) * amp * 0.3;
                  pts.push(vadd(base, vadd(vmul(td.basis.t, wobble), vmul(td.basis.b, Math.cos(f * 11 + td.seed) * amp * 0.55))));
                }
                const fade = clamp01(raw / 0.12) * (raw > 0.94 ? (1 - raw) / 0.06 : 1);
                strokeWorldPath(pts, td.color, 0.14 * fade, 4.6);
                strokeWorldPath(pts, td.color, 0.62 * fade, 1.45);
                strokeWorldPath(pts, C.white, 0.30 * fade, 0.6);
                const tip = pts[pts.length - 1];
                const tp = project(tip);
                if (tp && raw < 0.98) {
                  glowAt(tp.x, tp.y, 22, td.color, 0.7 * fade);
                  glowAt(tp.x, tp.y, 7, C.white, 0.85 * fade);
                }
              }
              const build = clamp01(age / 0.58);
              drawGlowAtCenter(env, r * (0.7 + build * 1.5), C.appHot, 0.18 * build * (1 - smoothstep(0.62, 1.0, age)));
              drawFlash(env, { delay: 0.57, duration: 0.46, size: 2.7, color: C.white, halo: C.app, opacity: 0.7 });
              drawShock(env, {
                start: 0.85, end: 2.7, duration: 0.85, delay: 0.57,
                core: C.appHot, tail: C.host, thickness: 0.03, rays: 10, seed, opacity: 0.55,
              });
              drawSparks(sparks, age, env, 0.75);
            },
          };
        },
      },
      {
        id: 'seed',
        name: 'Seed Bloom',
        tagline: 'A seed lands · filaments unfurl',
        duration: 1.82,
        look: 'A seed drops out of the field, lands with a small splash, and eight filaments unfurl from the impact point. The body blooms out of the flower rather than assembling. Most organic.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const basis = orthoBasis(fx.normal);
          const seedStart = vadd(envOrigin(body), vadd(V(0, r * 3.0, 0), vmul(basis.t, r * 0.2)));
          const filaments = [];
          for (let i = 0; i < 8; i++) {
            const ang = (i / 8) * TAU + (rng() * 2 - 1) * 0.18;
            const radial = vadd(vmul(basis.t, Math.cos(ang)), vmul(basis.b, Math.sin(ang)));
            const tangent = vadd(vmul(basis.t, -Math.sin(ang)), vmul(basis.b, Math.cos(ang)));
            const p0 = envOrigin(body);
            const p1 = vadd(p0, vadd(vmul(radial, r * 0.25), vmul(tangent, r * 0.2)));
            const p2 = vadd(p0, vadd(vmul(radial, r * (1.0 + rng() * 0.35)), vadd(vmul(tangent, r * (0.4 + rng() * 0.4)), vmul(fx.normal, r * 0.14))));
            const p3 = vadd(p0, vadd(vmul(radial, r * (1.3 + rng() * 0.4)), vadd(vmul(tangent, r * (0.1 + rng() * 0.3)), vmul(fx.normal, r * 0.12))));
            const pts = [];
            for (let j = 0; j <= 24; j++) pts.push(cubic(p0, p1, p2, p3, j / 24));
            filaments.push({
              pts, start: 0.45 + i * 0.026, duration: 0.34,
              color: i % 4 === 0 ? C.host : i % 3 === 0 ? C.appHot : C.ice,
            });
          }
          const splash = makeSparks(rng, 30, r, {
            colors: [C.white, C.appHot, C.host, C.violet],
            speed: [0.6, 2.7], tangential: 2.0, normalSpeed: 1.2, drag: 0.9,
            life: [0.28, 0.8], size: [0.01, 0.036], start: 0.26, delay: [0.37, 0.4],
          });
          const dust = makeSparks(rng, 22, r, {
            colors: [C.ice, C.violet, C.appHot], speed: [0.1, 0.6], tangential: 0.3,
            normalSpeed: 0.2, drag: 1.4, life: [0.5, 1.1], size: [0.012, 0.035],
            start: 0.8, delay: [0.9, 1.1],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.8) return 0;
              const t = clamp01((age - 0.8) / 0.28);
              let v = easeOutBack(t, 1.35);
              if (age < 1.0) v *= 0.6 + 0.4 * Math.abs(Math.sin(age * 78));
              return clamp(v, 0, 1.06);
            },
            draw(env) {
              const age = env.age;
              const center = env.center;
              const land = 0.39;
              const fall = clamp01(age / land);
              if (age < land + 0.03) {
                const pos = vadd(vlerp(seedStart, center, fall * fall), vmul(basis.t, Math.sin(fall * 9) * r * 0.11 * (1 - fall)));
                drawSeedTrail(seedStart, center, fall, basis, r, C.appHot, 0.5);
                const pr = project(pos);
                if (pr) {
                  glowAt(pr.x, pr.y, Math.max(18, r * 4.2 * pr.s), C.appHot, 0.7);
                  glowAt(pr.x, pr.y, Math.max(7, r * 1.35 * pr.s), C.white, 0.95);
                  ctx.strokeStyle = rgba(C.white, 0.92);
                  ctx.lineWidth = 1.15;
                  const s = Math.max(3, r * 0.46 * pr.s);
                  ctx.beginPath();
                  ctx.moveTo(pr.x - s, pr.y);
                  ctx.lineTo(pr.x, pr.y - s);
                  ctx.lineTo(pr.x + s, pr.y);
                  ctx.lineTo(pr.x, pr.y + s);
                  ctx.closePath();
                  ctx.stroke();
                }
              }
              drawFlash(env, { delay: 0.37, duration: 0.44, size: 2.7, color: C.white, halo: C.app, opacity: 0.68 });
              drawShock(env, {
                start: 0.5, end: 2.5, duration: 0.72, delay: 0.38,
                core: C.appHot, tail: C.host, thickness: 0.022, rays: 0, seed, opacity: 0.48,
              });
              if (age < 0.45) {
                const far = vadd(center, vmul(fx.normal, -r * 3.6 * (1 - fall)));
                line3(far, vlerp(center, seedStart, fall), C.appHot, 0.12 * (1 - fall), 0.8);
              }
              // unfurling filaments
              for (const f of filaments) {
                const raw = clamp01((age - f.start) / f.duration);
                if (raw <= 0) continue;
                const head = Math.max(2, Math.floor(raw * 24));
                const tail = Math.max(0, head - 12);
                const pts = [];
                for (let j = tail; j <= head; j++) pts.push(f.pts[j]);
                const fade = clamp01(raw / 0.1) * (1 - smoothstep(0.82, 1, raw));
                strokeWorldPath(pts, f.color, 0.16 * fade, 4.2);
                strokeWorldPath(pts, f.color, 0.7 * fade, 1.35);
                strokeWorldPath(pts, C.white, 0.26 * fade, 0.55);
                const tp = project(f.pts[head]);
                if (tp) {
                  glowAt(tp.x, tp.y, 18, f.color, 0.55 * fade);
                  glowAt(tp.x, tp.y, 6, C.white, 0.7 * fade);
                  ctx.fillStyle = rgba(C.white, 0.8 * fade);
                  ctx.beginPath();
                  ctx.arc(tp.x, tp.y, Math.max(0.9, r * 0.045 * tp.s), 0, TAU);
                  ctx.fill();
                }
              }
              drawSparks(splash, age, env, 0.8);
              drawSparks(dust, age, env, 0.55);
              drawFlash(env, { delay: 0.8, duration: 0.42, size: 2.4, color: C.ice, halo: C.app, opacity: 0.55 });
              drawShock(env, {
                start: 0.7, end: 2.9, duration: 0.8, delay: 0.8,
                core: C.ice, tail: C.appHot, thickness: 0.026, rays: 12, seed: seed + 2, opacity: 0.45,
              });
              drawGlowAtCenter(env, r * (1.0 + smoothstep(0.8, 1.2, age) * 1.4), C.appHot, 0.2 * smoothstep(0.8, 1.1, age) * (1 - smoothstep(1.1, 1.5, age)));
            },
          };
        },
      },
      {
        id: 'scan',
        name: 'Scanline',
        tagline: 'Swept into existence',
        duration: 1.62,
        look: 'A scan plane sweeps from the top of the body to the bottom, revealing only the geometry behind it. The body resolves in discrete bands with an instrument sweep. Most digital.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const sparks = makeSparks(rng, 26, r, {
            colors: [C.white, C.appHot, C.host, C.violet],
            speed: [1.0, 3.4], tangential: 1.4, normalSpeed: 1.2, drag: 0.95,
            life: [0.3, 0.82], size: [0.01, 0.038], start: 0.3, delay: [0.76, 0.82],
          });
          const motes = [];
          for (let i = 0; i < 7; i++) {
            motes.push({ phase: rng() * TAU, speed: 0.8 + rng() * 1.2, size: 0.8 + rng() * 1.4 });
          }
          const seed = rng() * 9;
          return {
            presence(age) {
              return age < 0.08 ? 0 : 1;
            },
            clip(age) {
              if (age < 0.08) return 0;
              if (age >= 0.8) return null;
              return easeInOutCubic(clamp01((age - 0.08) / 0.66));
            },
            draw(env) {
              const age = env.age;
              const bp = project(bodyVisual(body));
              if (!bp) return;
              const bodyScreenR = Math.max(14, (body.type === 'app' ? 0.55 : body.radius * 2.7) * bp.s);
              const span = bodyScreenR * 1.25;
              const raw = clamp01((age - 0.08) / 0.66);
              const progress = easeInOutCubic(raw);
              const y = bp.y - span + progress * span * 2;
              const x0 = bp.x - bodyScreenR * 1.55;
              const x1 = bp.x + bodyScreenR * 1.55;
              const visible = age >= 0.07 && age < 0.86;
              // ghost of the ring being reconstructed, so the scan has a body
              ctx.strokeStyle = rgba(C.dest, 0.12 * (1 - smoothstep(0.7, 0.95, age)));
              ctx.lineWidth = 0.7;
              ctx.beginPath();
              ctx.arc(bp.x, bp.y, bodyScreenR * 2.05, 0, TAU);
              ctx.stroke();
              ctx.strokeStyle = rgba(C.host, 0.045 * (1 - smoothstep(0.5, 0.9, age)));
              ctx.lineWidth = 1;
              ctx.beginPath();
              ctx.moveTo(bp.x, bp.y - bodyScreenR * 1.2);
              ctx.lineTo(bp.x, bp.y + bodyScreenR * 1.2);
              ctx.stroke();
              if (visible) {
                const grad = ctx.createLinearGradient(x0, y, x1, y);
                grad.addColorStop(0, rgba(C.host, 0));
                grad.addColorStop(0.14, rgba(C.host, 0.45));
                grad.addColorStop(0.5, rgba(C.white, 1));
                grad.addColorStop(0.86, rgba(C.host, 0.45));
                grad.addColorStop(1, rgba(C.host, 0));
                ctx.strokeStyle = rgba(C.host, 0.32);
                ctx.lineWidth = 13;
                ctx.beginPath();
                ctx.moveTo(x0, y);
                ctx.lineTo(x1, y);
                ctx.stroke();
                ctx.strokeStyle = grad;
                ctx.lineWidth = 2.2;
                ctx.beginPath();
                ctx.moveTo(x0, y);
                ctx.lineTo(x1, y);
                ctx.stroke();
                glowAt(bp.x, y, 38, C.host, 0.4);
                glowAt(bp.x, y, 12, C.white, 0.8);
                // the reconstructed slice edge
                ctx.strokeStyle = rgba(C.ice, 0.32);
                ctx.lineWidth = 0.8;
                ctx.beginPath();
                ctx.moveTo(bp.x - bodyScreenR * 1.2, y);
                ctx.lineTo(bp.x + bodyScreenR * 1.2, y);
                ctx.stroke();
                // ticks along the beam
                for (let i = 0; i < 9; i++) {
                  const tx = x0 + ((i + 0.5) / 9) * (x1 - x0);
                  ctx.strokeStyle = rgba(C.appHot, 0.2 + (i % 3) * 0.1);
                  ctx.lineWidth = 0.7;
                  ctx.beginPath();
                  ctx.moveTo(tx, y - 2.5);
                  ctx.lineTo(tx, y + 2.5);
                  ctx.stroke();
                }
                // motes falling in front of the beam
                for (let i = 0; i < motes.length; i++) {
                  const m = motes[i];
                  const mx = bp.x + Math.sin(simTime * m.speed + m.phase) * bodyScreenR * 1.35;
                  const my = y + Math.cos(simTime * m.speed * 0.8 + m.phase) * bodyScreenR * 0.2;
                  ctx.fillStyle = rgba(C.host, 0.35);
                  ctx.beginPath();
                  ctx.arc(mx, my, m.size, 0, TAU);
                  ctx.fill();
                }
              }
              if (age < 0.16) {
                const blip = 1 - age / 0.16;
                glowAt(bp.x, bp.y - span, 18, C.ice, 0.35 * blip);
              }
              drawFlash(env, { delay: 0.78, duration: 0.4, size: 2.4, color: C.white, halo: C.app, opacity: 0.62 });
              drawShock(env, {
                start: 0.9, end: 3.0, duration: 0.82, delay: 0.78,
                core: C.ice, tail: C.host, thickness: 0.028, rays: 16, seed, opacity: 0.55,
              });
              drawSparks(sparks, age, env, 0.75);
              drawGlowAtCenter(env, r * 1.3, C.appHot, 0.1 * (1 - smoothstep(0.8, 1.2, age)));
            },
          };
        },
      },
    ],
    disappear: [
      {
        id: 'implode',
        name: 'Implode',
        tagline: 'Gravity crush · silent flash',
        duration: 1.42,
        look: 'The body is crushed inward while the ring runs backward. A compressed flash is the only release. Quiet and final; it reads well when a destination has simply stopped existing.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const motes = makeMotes(rng, 44, r, {
            radius: [1.8, 3.1], spin: 2.1, normal: 1.0,
            size: [0.008, 0.034], colors: [C.ice, C.destHot, C.violet, C.host],
          });
          const sparks = makeSparks(rng, 20, r, {
            colors: [C.ice, C.destHot, C.violet],
            speed: [0.4, 2.0], tangential: 1.0, normalSpeed: 0.8, drag: 1.2,
            life: [0.25, 0.62], size: [0.01, 0.036], start: 0.35, delay: [0.52, 0.57],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.04) return 1;
              return Math.max(0, 1 - smoothstep(0.04, 0.62, age));
            },
            warp(age) {
              const p = clamp01(age / 0.64);
              return { sx: 1 + 0.11 * p, sy: 1 - 0.09 * p, rot: 0 };
            },
            draw(env) {
              const age = env.age;
              drawShock(env, {
                start: 2.8, end: 0.1, duration: 0.7,
                core: C.ice, tail: C.violet, thickness: 0.045, rays: 0, seed, opacity: 0.95,
              });
              drawShock(env, {
                start: 2.0, end: 0.06, duration: 0.78, delay: 0.08,
                core: C.destHot, tail: C.blue, thickness: 0.03, rays: 0, seed: seed + 3, opacity: 0.72,
              });
              drawShock(env, {
                start: 1.3, end: 0.04, duration: 0.62, delay: 0.18,
                core: C.white, tail: C.violet, thickness: 0.02, rays: 0, seed: seed + 5, opacity: 0.55,
              });
              drawConvergeMotes(motes, age, env, 0.62, age * 2.6, { opacity: 0.9, streaks: true, keep: 0.995 });
              drawGlowAtCenter(env, r * (1.3 + Math.max(0, 0.62 - age) * 2.6), C.destHot,
                0.28 * smoothstep(0.2, 0.56, age) * (1 - smoothstep(0.56, 0.9, age)));
              drawFlash(env, { delay: 0.58, duration: 0.46, size: 2.5, color: C.white, halo: C.violet, opacity: 0.85 });
              drawGlowAtCenter(env, r * 0.4, C.white, Math.max(0, 1 - Math.abs(age - 0.62) * 4) * 0.8);
              drawSparks(sparks, age, env, 0.7);
            },
          };
        },
      },
      {
        id: 'shear',
        name: 'Shear',
        tagline: 'Tilted split · shards peel',
        duration: 1.46,
        look: 'The body tilts, a clean cut opens across it, and the two halves peel away as shards. There is a short, readable beat between the cut and the break. Best for a deliberate retirement.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const shards = makeShards(rng, 26, r, {
            colors: [C.ice, C.destHot, C.violet, C.blue, C.white],
            speed: [1.5, 4.2], drift: 0.36, start: 0.62,
            len: [0.3, 0.75], wide: [0.03, 0.09], delay: [0.21, 0.27],
          });
          const sparks = makeSparks(rng, 40, r, {
            colors: [C.white, C.ice, C.violet, C.host],
            speed: [1.8, 4.8], tangential: 1.6, normalSpeed: 1.2, drag: 0.9,
            life: [0.3, 0.85], size: [0.01, 0.04], start: 0.32, delay: [0.22, 0.27],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.18) return 1;
              return Math.max(0, 1 - smoothstep(0.18, 0.34, age));
            },
            warp(age) {
              if (age > 0.34) return { sx: 1, sy: 1, rot: 0 };
              const p = smoothstep(0.03, 0.3, age);
              return { sx: 1 + 0.2 * p, sy: 1 - 0.12 * p, rot: 0.5 * p };
            },
            draw(env) {
              const age = env.age;
              const bp = project(bodyVisual(body));
              if (bp && age > 0.07 && age < 0.42) {
                const bodyScreenR = Math.max(13, (body.type === 'app' ? 0.55 : body.radius * 2.8) * bp.s);
                const cut = smoothstep(0.07, 0.16, age) * (1 - smoothstep(0.28, 0.42, age));
                const ang = -0.58;
                const len = bodyScreenR * 2.2;
                const x0 = bp.x - Math.cos(ang) * len;
                const y0 = bp.y - Math.sin(ang) * len;
                const x1 = bp.x + Math.cos(ang) * len;
                const y1 = bp.y + Math.sin(ang) * len;
                const grad = ctx.createLinearGradient(x0, y0, x1, y1);
                grad.addColorStop(0, rgba(C.host, 0));
                grad.addColorStop(0.5, rgba(C.white, 0.85 * cut));
                grad.addColorStop(1, rgba(C.violet, 0));
                ctx.strokeStyle = grad;
                ctx.lineWidth = 1.2;
                ctx.beginPath();
                ctx.moveTo(x0, y0);
                ctx.lineTo(x1, y1);
                ctx.stroke();
                ctx.strokeStyle = rgba(C.ice, 0.16 * cut);
                ctx.lineWidth = 7;
                ctx.stroke();
                glowAt(bp.x, bp.y, bodyScreenR * 1.7, C.violet, 0.22 * cut);
              }
              drawFlash(env, { delay: 0.21, duration: 0.38, size: 2.4, color: C.white, halo: C.violet, opacity: 0.66 });
              drawSparks(sparks, age, env, 0.86);
              drawShards(shards, age, env, 0.92);
              const p = clamp01((age - 0.2) / 0.9);
              const radius = r * (0.9 + easeOutCubic(p) * 3.0);
              const alpha = (1 - p) * 0.5;
              if (alpha > 0.004) {
                strokeArc(env.center, env.normal, radius, 0.35, 1.35, C.violet, alpha, 1.1);
                strokeArc(env.center, env.normal, radius, 2.8, 1.15, C.ice, alpha * 0.6, 0.8);
              }
              drawShock(env, {
                start: 1.0, end: 3.4, duration: 0.86, delay: 0.22,
                core: C.destHot, tail: C.dest, thickness: 0.018, rays: 0, seed, opacity: 0.32,
              });
            },
          };
        },
      },
      {
        id: 'dissolve',
        name: 'Dissolve',
        tagline: 'Surface lets go · drifting ash',
        duration: 1.66,
        look: 'No fracture: the surface simply lets go into a slow cloud of ash while the orbit ring breaks into drifting arcs. The gentlest exit; useful if disappearances are frequent.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const ash = [];
          for (let i = 0; i < 92; i++) {
            const ang = rng() * TAU;
            const rad = Math.sqrt(rng()) * 0.82 * r;
            ash.push({
              ang, rad,
              nOff: (rng() * 2 - 1) * r * 0.35,
              drift: (0.2 + rng() * 0.9) * r,
              rise: (0.15 + rng() * 0.55) * r,
              delay: rng() * 0.42,
              life: 0.55 + rng() * 0.7,
              size: 0.012 + rng() * 0.028,
              color: rng() > 0.72 ? C.violet : rng() > 0.45 ? C.ice : C.destHot,
            });
          }
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.12) return 1;
              const v = 1 - smoothstep(0.12, 0.93, age);
              return clamp01(v * (0.92 + 0.08 * Math.sin(age * 41)));
            },
            warp(age) {
              const p = smoothstep(0, 0.9, age);
              return { sx: 1 + 0.045 * p, sy: 1 + 0.05 * p, rot: 0 };
            },
            draw(env) {
              const age = env.age;
              const { t, b } = orthoBasis(normal);
              for (const a of ash) {
                const local = age - a.delay;
                if (local < 0 || local > a.life) continue;
                const p = clamp01(local / a.life);
                const dir = vadd(vmul(t, Math.cos(a.ang)), vmul(b, Math.sin(a.ang)));
                const base = vadd(env.center, vadd(vmul(dir, a.rad), vmul(normal, a.nOff)));
                const pos = vadd(base, vadd(vmul(dir, a.drift * easeOutCubic(p)), V(0, a.rise * easeOutCubic(p), 0)));
                const pr = project(pos);
                if (!pr) continue;
                const alpha = Math.pow(1 - p, 1.2) * clamp01(local / 0.08) * 0.82;
                if (alpha <= 0.004) continue;
                ctx.fillStyle = rgba(a.color, alpha);
                ctx.beginPath();
                ctx.arc(pr.x, pr.y, Math.max(0.9, a.size * pr.s * 1.8), 0, TAU);
                ctx.fill();
                if (a.size > 0.025) glowAt(pr.x, pr.y, 11, a.color, alpha * 0.4);
              }
              const p = clamp01(age / 1.3);
              const radius = r * (1.2 + easeOutCubic(p) * 2.0);
              if (p < 0.92) {
                const alpha = (1 - p) * 0.3;
                strokeArc(env.center, env.normal, radius, 0.1, 1.6, C.destHot, alpha, 0.8);
                strokeArc(env.center, env.normal, radius * 0.93, 2.1, 1.2, C.violet, alpha * 0.7, 0.7);
                strokeArc(env.center, env.normal, radius * 1.08, 4.0, 0.8, C.ice, alpha * 0.5, 0.7);
              }
              const bp = project(bodyVisual(body));
              if (bp) {
                const bodyScreenR = Math.max(12, (body.type === 'app' ? 0.55 : body.radius * 2.7) * bp.s);
                const rim = 1 - smoothstep(0.4, 1.15, age);
                ctx.strokeStyle = rgba(C.destHot, 0.5 * rim);
                ctx.lineWidth = 1.1;
                const rimR = bodyScreenR * (1 + smoothstep(0.2, 1.2, age) * 0.45);
                for (let k = 0; k < 4; k++) {
                  const a0 = k * (TAU / 4) + age * 0.5 + 0.2;
                  ctx.beginPath();
                  ctx.arc(bp.x, bp.y, rimR, a0, a0 + 0.8);
                  ctx.stroke();
                }
                glowAt(bp.x, bp.y, bodyScreenR * 5.5, C.violet, 0.14 * rim);
              }
              drawFlash(env, { delay: 0.82, duration: 0.5, size: 1.8, color: C.ice, halo: C.dest, opacity: 0.35 });
              drawShock(env, {
                start: 1.1, end: 2.9, duration: 0.9, delay: 0.72,
                core: C.ice, tail: C.violet, thickness: 0.012, rays: 0, seed, opacity: 0.24,
              });
            },
          };
        },
      },
      {
        id: 'fold',
        name: 'Fold',
        tagline: 'Collapse to a seam · soft click',
        duration: 1.18,
        look: 'The body folds along one axis into a bright seam, holds for a beat, then blinks out. Minimal debris, calm timing. The neatest fit for apps that only briefly leave the field.',
        create(body, rng, fx) {
          const r = fx.r;
          const normal = fx.normal;
          const sparks = makeSparks(rng, 14, r, {
            colors: [C.ice, C.destHot, C.violet],
            speed: [0.3, 1.6], tangential: 1.2, normalSpeed: 0.6, drag: 1.2,
            life: [0.25, 0.65], size: [0.008, 0.028], start: 0.3, delay: [0.3, 0.38],
          });
          const seed = rng() * 9;
          return {
            presence(age) {
              if (age < 0.2) return 1;
              return Math.max(0, 1 - smoothstep(0.22, 0.55, age));
            },
            warp(age) {
              if (age > 0.58) return { sx: 1, sy: 1, rot: 0 };
              const p = smoothstep(0.1, 0.58, age);
              return { sx: 1 + 0.46 * p, sy: lerp(1, 0.012, easeInCubic(p)), rot: -0.48 * p };
            },
            draw(env) {
              const age = env.age;
              const bp = project(bodyVisual(body));
              if (!bp) return;
              const bodyScreenR = Math.max(12, (body.type === 'app' ? 0.55 : body.radius * 2.7) * bp.s);
              const p = smoothstep(0.12, 0.56, age);
              const seam = 1 - Math.abs(p - 0.62) / 0.62;
              if (age < 0.72 && seam > 0) {
                const sx = bodyScreenR * (1 + p * 0.7);
                const grad = ctx.createLinearGradient(bp.x - sx, bp.y, bp.x + sx, bp.y);
                grad.addColorStop(0, rgba(C.dest, 0));
                grad.addColorStop(0.12, rgba(C.destHot, 0.7 * seam));
                grad.addColorStop(0.5, rgba(C.white, 1 * seam));
                grad.addColorStop(0.88, rgba(C.destHot, 0.7 * seam));
                grad.addColorStop(1, rgba(C.dest, 0));
                ctx.strokeStyle = rgba(C.destHot, 0.18 * seam);
                ctx.lineWidth = 9;
                ctx.beginPath();
                ctx.moveTo(bp.x - sx, bp.y);
                ctx.lineTo(bp.x + sx, bp.y);
                ctx.stroke();
                ctx.strokeStyle = grad;
                ctx.lineWidth = 1.7;
                ctx.beginPath();
                ctx.moveTo(bp.x - sx, bp.y);
                ctx.lineTo(bp.x + sx, bp.y);
                ctx.stroke();
                glowAt(bp.x, bp.y, sx * 1.1, C.ice, 0.32 * seam);
              }
              drawFlash(env, { delay: 0.42, duration: 0.34, size: 1.4, color: C.white, halo: C.dest, opacity: 0.48 });
              drawShock(env, {
                start: 0.7, end: 2.3, duration: 0.7, delay: 0.36,
                core: C.destHot, tail: C.violet, thickness: 0.01, rays: 0, seed, opacity: 0.3,
              });
              drawGlowAtCenter(env, r * 0.6, C.white, Math.max(0, 1 - Math.abs(age - 0.48) * 5) * 0.7);
              drawSparks(sparks, age, env, 0.55);
            },
          };
        },
      },
    ],
  };

  // ── effect engine ─────────────────────────────────────────────────────
  const IDENTITY_WARP = { sx: 1, sy: 1, rot: 0 };
  let effects = [];
  let effectCounter = 0;
  let camPause = 0;

  function currentStudy() {
    return STUDIES[state.cat][state.idx];
  }
  function currentMeta() {
    return CATEGORY_META[state.cat];
  }
  function currentTakeNumber() {
    let n = 0;
    for (const cat of ['impact', 'appear', 'disappear']) {
      if (cat === state.cat) return n + state.idx + 1;
      n += STUDIES[cat].length;
    }
    return 1;
  }
  function focusedAppBody() {
    return appByIndex(state.focusApp);
  }
  function focusedDomainBody() {
    return domainByIndex(state.focusDomain);
  }
  function targetBodies() {
    if (state.target === 'app') return [focusedAppBody()];
    if (state.target === 'domain') return [focusedDomainBody()];
    return [focusedAppBody(), focusedDomainBody()];
  }
  function partnerFor(b) {
    const preferredType = b.type === 'app' ? 'domain' : 'app';
    const preferred = preferredType === 'app' ? focusedAppBody() : focusedDomainBody();
    const linked = [];
    for (const w of wires) {
      if (b.type === 'app' && w.app === b) linked.push(w.domain);
      if (b.type === 'domain' && w.domain === b) linked.push(w.app);
    }
    if (linked.includes(preferred)) return preferred;
    return linked[0] || (preferredType === 'app' ? apps[0] : domains[0]);
  }

  function resetRecoil(b) {
    b.recoil = V();
    b.recoilVel = V();
    b.recoilActive = false;
  }

  function clearAllEffects() {
    for (const e of effects) {
      if (e.body && e.body.presenceFx === e) e.body.presenceFx = null;
      e.done = true;
    }
    effects = [];
    for (const b of bodies) {
      b.presenceFx = null;
      b.warp = { sx: 1, sy: 1, rot: 0 };
      b.clip = null;
      b.restoreAt = 0;
      if (b.resting === 0) b.resting = 1;
    }
  }

  function launch(body, cat, study) {
    // a take that lands on a body which is still leaving gets that body back
    body.presenceFx = null;
    body.warp = { sx: 1, sy: 1, rot: 0 };
    body.clip = null;
    body.restoreAt = 0;
    body.resting = 1;
    if (cat === 'impact') {
      body.presence = 1;
    } else if (cat === 'disappear') {
      body.presence = 1;
      resetRecoil(body);
    } else {
      body.presence = 0;
      body.resting = 0;
      resetRecoil(body);
    }

    const source = cat === 'impact' ? partnerFor(body) : null;
    let normal;
    if (cat === 'impact') {
      normal = source ? vnorm(vsub(bodyAnchor(body), bodyAnchor(source))) : body.type === 'app' ? body.normal : bodyFxNormal(body);
      if (vlen(normal) < 0.01) normal = bodyFxNormal(body);
    } else {
      normal = bodyFxNormal(body);
    }
    const r = bodyFxRadius(body);
    const seed = (body.seed * 7919 + study.id.length * 131 + effectCounter * 2654435761) >>> 0;
    effectCounter++;
    const rng = mulberry32(seed);
    const fxInfo = { r, normal, source };
    const created = study.create(body, rng, fxInfo);
    const inst = {
      uid: effectCounter,
      cat,
      study,
      body,
      source,
      normal,
      r,
      anchor: bodyAnchor(body),
      age: 0,
      flight: cat === 'impact' ? study.flight || 0 : 0,
      total: (cat === 'impact' ? study.flight || 0 : 0) + study.duration,
      progress: 0,
      detonated: false,
      done: false,
      created,
    };
    if (cat === 'appear' || cat === 'disappear') body.presenceFx = inst;
    effects.push(inst);
    return inst;
  }

  function applyDetonation(e) {
    e.detonated = true;
    const b = e.body;
    b.flash = 0;
    b.resting = 1;
    if (!b.presenceFx) b.presence = Math.max(b.presence, 0.92);
    const soft = b.type === 'app' ? Math.max(b.radius, 0.18) : b.radius;
    // Keep the ring plane true to the packet tangent, but bias the visible
    // recoil toward the screen so the hit always reads as a knock, even when
    // the source is almost directly behind the target.
    let recoilDir = e.normal;
    if (e.source) {
      const raw = vsub(e.anchor, bodyAnchor(e.source));
      const sx = vdot(raw, camState.right);
      const sy = vdot(raw, camState.up);
      if (Math.hypot(sx, sy) > 0.01) {
        recoilDir = vnorm(vadd(vadd(vmul(camState.right, sx), vmul(camState.up, sy)), vmul(camState.forward, 0.18)));
      }
    }
    e.recoilDir = recoilDir;
    const impulse = soft * 46 * (e.study.recoil || 1);
    b.recoilVel = vadd(b.recoilVel, vmul(recoilDir, impulse));
    const cap = soft * 66;
    if (vlen(b.recoilVel) > cap) b.recoilVel = vmul(vnorm(b.recoilVel), cap);
    b.recoilActive = true;
    if (!state.reduced) shakeAmp = Math.max(shakeAmp, e.study.shake || 2.4);
  }

  function finishEffect(e) {
    e.done = true;
    const b = e.body;
    if (e.cat === 'appear') {
      b.presenceFx = null;
      b.presence = 1;
      b.resting = 1;
      b.warp = { sx: 1, sy: 1, rot: 0 };
      b.clip = null;
    } else if (e.cat === 'disappear') {
      b.presenceFx = null;
      b.presence = 0;
      b.resting = 0;
      b.restoreAt = simTime + 1.2;
      b.warp = { sx: 1, sy: 1, rot: 0 };
      b.clip = null;
    }
  }

  function updateEffects(dt) {
    for (const e of effects) {
      if (e.done) continue;
      e.age += dt;
      const b = e.body;
      if (e.cat === 'impact') {
        if (!e.detonated && e.age >= e.flight) applyDetonation(e);
        e.progress = clamp01((e.age - e.flight) / e.study.duration);
        if (e.age >= e.total) e.done = true;
      } else {
        e.progress = clamp01(e.age / e.study.duration);
        if (e.created.presence) b.presence = clamp(e.created.presence(e.age), 0, 1.12);
        if (e.created.warp) b.warp = e.created.warp(e.age) || { sx: 1, sy: 1, rot: 0 };
        if (e.created.clip) {
          const c = e.created.clip(e.age);
          b.clip = c == null ? null : clamp01(c);
        }
        if (e.age >= e.study.duration) finishEffect(e);
      }
    }
    effects = effects.filter((e) => !e.done);
  }

  function updateBodies(dt) {
    for (const b of bodies) {
      if (b.flash < 9) b.flash += dt;
      if (b.recoilActive) {
        let remaining = dt;
        const k = 140;
        const damping = 23.7;
        while (remaining > 1e-5) {
          const h = Math.min(remaining, 1 / 120);
          const ax = -b.recoil.x * k - b.recoilVel.x * damping;
          const ay = -b.recoil.y * k - b.recoilVel.y * damping;
          const az = -b.recoil.z * k - b.recoilVel.z * damping;
          b.recoilVel = vadd(b.recoilVel, V(ax * h, ay * h, az * h));
          b.recoil = vadd(b.recoil, vmul(b.recoilVel, h));
          remaining -= h;
        }
        if (vlen(b.recoil) < b.radius * 0.002 && vlen(b.recoilVel) < b.radius * 0.02) {
          resetRecoil(b);
        }
      }
      if (!b.presenceFx) {
        if (b.resting === 0 && b.restoreAt > 0 && simTime >= b.restoreAt) {
          b.resting = 1;
          b.restoreAt = 0;
        }
        if (Math.abs(b.resting - b.presence) > 0.0005) {
          b.presence += (b.resting - b.presence) * Math.min(1, dt * 7);
          if (Math.abs(b.resting - b.presence) < 0.0015) b.presence = b.resting;
        } else {
          b.presence = b.resting;
        }
      }
    }
  }

  function effectEnv(e) {
    const age = e.cat === 'impact' ? Math.max(0, e.age - e.flight) : e.age;
    return {
      age,
      t: clamp01(age / e.study.duration),
      center: e.anchor,
      normal: e.normal,
      r: e.r,
      body: e.body,
      source: e.source,
      study: e.study,
    };
  }

  function drawProjectile(e) {
    const u = clamp01(e.age / e.flight);
    const source = bodyAnchor(e.source);
    const target = e.anchor;
    const control = bowControl(source, target, 0.85);
    const color = e.body.type === 'domain' ? C.violet : C.host;
    // guide
    const guide = [];
    for (let i = 0; i <= 28; i++) guide.push(quad(source, control, target, i / 28));
    strokeWorldPath(guide, color, 0.045, 0.6);
    // tail
    const pts = [];
    for (let i = 0; i <= 16; i++) {
      const uu = clamp01(u - i * 0.022);
      if (uu <= 0) continue;
      pts.push(quad(source, control, target, uu));
    }
    if (pts.length > 1) {
      for (let i = 0; i < pts.length - 1; i++) {
        const a = project(pts[i]);
        const b = project(pts[i + 1]);
        if (!a || !b) continue;
        const alpha = (1 - i / pts.length) * 0.55;
        ctx.strokeStyle = rgba(i % 3 === 0 ? C.white : color, alpha);
        ctx.lineWidth = Math.max(0.8, 2.2 * (1 - i / pts.length));
        ctx.lineCap = 'round';
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
    }
    const head = quad(source, control, target, u);
    const hp = project(head);
    if (hp) {
      glowAt(hp.x, hp.y, 28, color, 0.45);
      glowAt(hp.x, hp.y, 7, C.white, 0.9);
      ctx.fillStyle = rgba(C.white, 0.9);
      ctx.beginPath();
      ctx.arc(hp.x, hp.y, 1.6, 0, TAU);
      ctx.fill();
    }
    const tp = project(target);
    if (tp) {
      const flare = smoothstep(0.55, 1, u);
      glowAt(tp.x, tp.y, 20 + u * 34, color, 0.1 + flare * 0.16);
      glowAt(tp.x, tp.y, 10 + u * 14, C.white, flare * 0.2);
    }
  }

  function drawEffects() {
    ctx.globalCompositeOperation = 'lighter';
    const sorted = effects
      .slice()
      .sort((a, b) => {
        const pa = project(a.anchor);
        const pb = project(b.anchor);
        return (pb ? pb.z : 0) - (pa ? pa.z : 0);
      });
    for (const e of sorted) {
      if (e.cat === 'impact') {
        if (e.age < e.flight) {
          drawProjectile(e);
        } else {
          e.created.draw(effectEnv(e));
        }
      } else {
        e.created.draw(effectEnv(e));
      }
    }
  }

  // ── study / target UI ─────────────────────────────────────────────────
  const CATEGORY_META = {
    impact: { label: 'IMPACT', sub: 'blast · recoil', code: 'B', accent: '#b79bff' },
    appear: { label: 'APPEAR', sub: 'birth · condense', code: 'A', accent: '#7ff0d0' },
    disappear: { label: 'DISAPPEAR', sub: 'retire · collapse', code: 'D', accent: '#8db4ff' },
  };
  const ORDER = ['impact', 'appear', 'disappear'];
  let rowsByCat = { impact: [], appear: [], disappear: [] };

  function buildLibrary() {
    groupsEl.innerHTML = '';
    for (const cat of ORDER) {
      const meta = CATEGORY_META[cat];
      const group = document.createElement('section');
      group.className = 'group cat-' + cat;
      const head = document.createElement('div');
      head.className = 'group-head';
      head.innerHTML = `<span class="group-name">${meta.label}</span><span class="group-sub">${meta.sub}</span>`;
      group.appendChild(head);
      STUDIES[cat].forEach((study, idx) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'take';
        btn.dataset.cat = cat;
        btn.dataset.idx = String(idx);
        btn.innerHTML = `
          <span class="take-key">${meta.code}${idx + 1}</span>
          <span class="take-copy">
            <span class="take-name">${study.name}</span>
            <span class="take-tag">${study.tagline}</span>
          </span>
          <span class="take-mark"></span>`;
        btn.setAttribute('aria-pressed', 'false');
        btn.addEventListener('click', () => selectStudy(cat, idx));
        group.appendChild(btn);
        rowsByCat[cat].push(btn);
      });
      groupsEl.appendChild(group);
    }
  }

  function targetLabel() {
    if (state.target === 'app') return focusedAppBody().short;
    if (state.target === 'domain') return focusedDomainBody().short;
    return `${focusedAppBody().short} + ${focusedDomainBody().short}`;
  }

  function roleChip(type) {
    return type === 'app'
      ? '<span class="role app">APP</span>'
      : '<span class="role dest">DEST</span>';
  }

  function updateInfo() {
    const study = currentStudy();
    const meta = currentMeta();
    const take = currentTakeNumber();
    takeNoEl.textContent = String(take).padStart(2, '0');
    takeNameEl.textContent = study.name;
    takeKindEl.textContent = meta.label;
    takeTagEl.textContent = study.tagline;
    takeDurEl.textContent = `${study.duration.toFixed(2)} s`;
    takeLookEl.textContent = study.look;
    notesEl.style.setProperty('--row-accent', meta.accent);
    takeKindEl.style.color = meta.accent;
    takeKindEl.style.borderColor = rgba(meta.accent, 0.34);

    if (state.cat === 'impact') {
      const r = study.recoil || 1;
      takeRecoilEl.textContent = `${r.toFixed(2)}× · ${study.recoilLabel || 'impact'}`;
      recoilFillEl.style.width = `${clamp01(r / 1.5) * 100}%`;
      recoilTrackEl.style.display = '';
      recoilScaleEl.style.display = 'flex';
      const both = state.target === 'both';
      const who = state.target === 'app' ? 'DESTINATION → APP' : 'APP → DESTINATION';
      incomingLineEl.textContent = both ? 'INBOUND + OUTBOUND · BOTH DIRECTIONS' : who;
      motionLabelEl.textContent = 'RECOIL NOTE';
      motionNoteEl.textContent = state.target === 'app'
        ? 'The impulse rides the arrival tangent. The app orb lifts off its shell pad, stretches the stem, and settles without a second bounce.'
        : state.target === 'domain'
          ? 'The impulse rides the arrival tangent. The whole destination assembly is knocked out of the ring and settles without a second bounce.'
          : 'Every blast applies the impulse at its own arrival tangent: the app orb lifts off its pad, the destination assembly travels, and both springs settle cleanly.';
    } else {
      takeRecoilEl.textContent = '— · no impact';
      recoilFillEl.style.width = '0%';
      recoilTrackEl.style.display = 'none';
      recoilScaleEl.style.display = 'none';
      incomingLineEl.textContent = state.cat === 'appear' ? 'ARRIVAL · PRESENCE 0 → 1' : 'RETIREMENT · PRESENCE 1 → 0';
      motionLabelEl.textContent = 'PRESENCE NOTE';
      motionNoteEl.textContent = state.cat === 'appear'
        ? 'The study drives presence from 0 → 1. The body is not drawn until the reveal; its app gyros or destination orbit resolve with the same clock.'
        : 'The study drives presence from 1 → 0. The body returns 1.2 s after the take, so the field stays explorable between comparisons.';
    }

    let html = '';
    if (state.target === 'app' || state.target === 'both') {
      html += `${roleChip('app')}<b>${focusedAppBody().name}</b>`;
    }
    if (state.target === 'both') html += '<span class="arrow">+</span>';
    if (state.target === 'domain' || state.target === 'both') {
      html += `${roleChip('domain')}<b>${focusedDomainBody().name}</b>`;
    }
    targetLineEl.innerHTML = html;

    const tLabel = state.target === 'both' ? 'APP + DESTINATION' : state.target === 'app' ? 'APP' : 'DESTINATION';
    captionBodyEl.textContent = `${study.name} · ${tLabel}`;
    cleanTakeEl.textContent = `${String(take).padStart(2, '0')} / ${study.name.toUpperCase()}`;
    targetSegEl.querySelectorAll('button').forEach((btn) => {
      const on = btn.dataset.target === state.target;
      btn.classList.toggle('on', on);
      btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  function syncSelectionUI() {
    for (const cat of ORDER) {
      for (const btn of rowsByCat[cat]) {
        const active = cat === state.cat && Number(btn.dataset.idx) === state.idx;
        btn.classList.toggle('is-active', active);
        btn.setAttribute('aria-pressed', active ? 'true' : 'false');
      }
    }
    updateInfo();
  }

  function selectStudy(cat, idx, opts = {}) {
    if (!opts.fromReel) stopReel();
    bootPlayed = true;
    state.cat = cat;
    state.idx = clamp(idx, 0, STUDIES[cat].length - 1);
    syncSelectionUI();
    if (opts.play !== false) playCurrent({ fromReel: !!opts.fromReel });
  }

  function stepTake(delta, opts = {}) {
    if (!opts.fromReel) stopReel();
    let flat = 0;
    const flatIndex = ORDER.indexOf(state.cat) * 4 + state.idx;
    flat = (flatIndex + delta + 12) % 12;
    const cat = ORDER[Math.floor(flat / 4)];
    state.cat = cat;
    state.idx = flat % 4;
    syncSelectionUI();
    if (opts.play) playCurrent({ fromReel: !!opts.fromReel });
  }

  function playCurrent(opts = {}) {
    if (!opts.fromReel) stopReel();
    bootPlayed = true;
    rebuildCamera();
    clearAllEffects();
    const study = currentStudy();
    const targets = targetBodies();
    for (const b of targets) launch(b, state.cat, study);
    syncLiveUI();
    updateInfo();
  }

  function playOnBody(b) {
    bootPlayed = true;
    state.target = b.type;
    if (b.type === 'app') state.focusApp = b.index;
    else state.focusDomain = b.index;
    updateInfo();
    playCurrent();
  }

  // ── reel ──────────────────────────────────────────────────────────────
  function stopReel() {
    if (!state.reel) return;
    state.reel = false;
    reelPrimed = false;
    reelDue = 0;
    reelBtn.classList.remove('on');
    reelBtn.setAttribute('aria-pressed', 'false');
  }

  function updateReel() {
    if (!state.reel || effects.length > 0) return;
    if (reelDue === 0) reelDue = simTime + 0.28;
    if (simTime < reelDue) return;
    if (reelPrimed) stepTake(1, { play: false, fromReel: true });
    else reelPrimed = true;
    playCurrent({ fromReel: true });
    reelDue = simTime + currentStudy().duration + (currentStudy().flight || 0) + 0.6;
  }

  // ── live UI ───────────────────────────────────────────────────────────
  function syncLiveUI() {
    const active = effects.filter((e) => !e.done);
    if (active.length > 0) {
      let prog = 0;
      let age = 0;
      for (const e of active) {
        prog = Math.max(prog, e.progress || 0);
        age = Math.max(age, e.age);
      }
      liveStateEl.textContent = 'LIVE';
      liveTimeEl.textContent = `${age.toFixed(2)} s`;
      liveFillEl.style.width = `${(prog * 100).toFixed(2)}%`;
      dockFillEl.style.transform = `scaleX(${clamp01(prog).toFixed(4)})`;
    } else {
      liveStateEl.textContent = state.reel ? 'REEL' : 'READY';
      liveTimeEl.textContent = '0.00 s';
      liveFillEl.style.width = '0%';
      dockFillEl.style.transform = 'scaleX(0)';
    }
  }

  function showToast(text, hold = 2.0) {
    toastEl.textContent = text;
    toastEl.classList.add('show');
    toastUntil = simTime + hold;
  }

  function cycleTarget() {
    const order = ['both', 'app', 'domain'];
    state.target = order[(order.indexOf(state.target) + 1) % order.length];
    updateInfo();
  }

  function setTarget(target) {
    state.target = target;
    updateInfo();
  }

  // ── picking / pointer ─────────────────────────────────────────────────
  function pickBody(x, y) {
    let best = null;
    for (const b of bodies) {
      const pr = project(bodyVisual(b));
      if (!pr || !visibleOnScreen(pr, 40)) continue;
      const hit = b.type === 'app' ? Math.max(18, 0.58 * pr.s) : Math.max(17, b.radius * 2.95 * pr.s);
      const d = Math.hypot(pr.x - x, pr.y - y);
      if (d <= hit && (!best || d / hit < best.ratio)) best = { body: b, ratio: d / hit };
    }
    return best ? best.body : null;
  }

  let pointerDown = false;
  let pointerStart = { x: 0, y: 0 };
  let pointerLast = { x: 0, y: 0 };
  let pointerMoved = 0;

  function onPointerDown(e) {
    if (e.button != null && e.button !== 0) return;
    pointerDown = true;
    pointerStart = { x: e.clientX, y: e.clientY };
    pointerLast = { x: e.clientX, y: e.clientY };
    pointerMoved = 0;
    state.dragging = false;
    canvas.setPointerCapture?.(e.pointerId);
  }

  function onPointerMove(e) {
    if (pointerDown) {
      const dx = e.clientX - pointerLast.x;
      const dy = e.clientY - pointerLast.y;
      pointerLast = { x: e.clientX, y: e.clientY };
      pointerMoved += Math.abs(dx) + Math.abs(dy);
      if (pointerMoved > 6) {
        if (!state.dragging) {
          state.dragging = true;
          canvas.classList.add('dragging');
          canvas.classList.remove('pointing');
          camPause = 3.5;
        }
        cam.yaw -= dx * 0.0055;
        cam.pitch = clamp(cam.pitch - dy * 0.0045, 0.04, 1.18);
        camPause = 3.5;
      }
      return;
    }
    const hit = pickBody(e.clientX, e.clientY);
    state.hover = hit;
    canvas.classList.toggle('pointing', !!hit);
  }

  function onPointerUp(e) {
    if (!pointerDown) return;
    pointerDown = false;
    canvas.releasePointerCapture?.(e.pointerId);
    canvas.classList.remove('dragging');
    const wasDragging = state.dragging;
    state.dragging = false;
    if (!wasDragging && pointerMoved < 6) {
      const hit = pickBody(e.clientX, e.clientY);
      if (hit) playOnBody(hit);
      else playCurrent();
    }
    state.hover = pickBody(e.clientX, e.clientY);
    canvas.classList.toggle('pointing', !!state.hover);
  }

  function onPointerLeave() {
    if (!pointerDown) {
      state.hover = null;
      canvas.classList.remove('pointing');
    }
  }

  function onWheel(e) {
    e.preventDefault();
    const factor = Math.exp(clamp(e.deltaY, -120, 120) * 0.0016);
    cam.dist = clamp(cam.dist * factor, 25, 46);
    camPause = 3.5;
  }

  // ── keyboard ──────────────────────────────────────────────────────────
  function onKeyDown(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key;
    const onButton = e.target && e.target.closest && e.target.closest('button');
    if ((key === ' ' || key === 'Enter') && onButton) return;
    if (key === ' ') {
      e.preventDefault();
      playCurrent();
    } else if (key >= '1' && key <= '4') {
      e.preventDefault();
      selectStudy(state.cat, Number(key) - 1);
    } else if (key === 'ArrowLeft') {
      e.preventDefault();
      stepTake(-1, { play: true });
    } else if (key === 'ArrowRight') {
      e.preventDefault();
      stepTake(1, { play: true });
    } else if (key === 'r' || key === 'R') {
      toggleReel();
    } else if (key === 's' || key === 'S') {
      toggleSlow();
    } else if (key === 't' || key === 'T') {
      cycleTarget();
    } else if (key === 'Escape' && state.reel) {
      stopReel();
      syncLiveUI();
    }
  }

  // ── buttons ───────────────────────────────────────────────────────────
  function toggleSlow() {
    state.slow = !state.slow;
    slowBtn.classList.toggle('on', state.slow);
    slowBtn.setAttribute('aria-pressed', state.slow ? 'true' : 'false');
    showToast(state.slow ? 'SLOW MOTION · 0.35×' : 'REAL TIME · 1.0×');
  }

  function toggleReel() {
    state.reel = !state.reel;
    reelBtn.classList.toggle('on', state.reel);
    reelBtn.setAttribute('aria-pressed', state.reel ? 'true' : 'false');
    if (state.reel) {
      reelDue = 0;
      reelPrimed = false;
      showToast('STUDY REEL · ALL 12 TAKES');
    } else {
      showToast('STUDY REEL OFF');
    }
    syncLiveUI();
  }

  function bindUI() {
    playBtn.addEventListener('click', () => playCurrent());
    prevBtn.addEventListener('click', () => stepTake(-1, { play: true }));
    nextBtn.addEventListener('click', () => stepTake(1, { play: true }));
    slowBtn.addEventListener('click', toggleSlow);
    reelBtn.addEventListener('click', toggleReel);
    targetSegEl.querySelectorAll('button').forEach((btn) => {
      btn.addEventListener('click', () => setTarget(btn.dataset.target));
    });
    canvas.addEventListener('pointerdown', onPointerDown);
    canvas.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('pointercancel', onPointerUp);
    canvas.addEventListener('pointerleave', onPointerLeave);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('resize', () => {
      resize();
      if (FREEZE) {
        syncLiveUI();
        render();
      }
    });
    document.addEventListener('visibilitychange', () => {
      lastTime = 0;
    });
  }

  // ── render loop ───────────────────────────────────────────────────────
  function render() {
    rebuildCamera();
    ctx.setTransform(view.dpr, 0, 0, view.dpr, 0, 0);
    ctx.clearRect(0, 0, view.w, view.h);
    drawStars();
    ctx.save();
    if (!state.reduced && shakeAmp > 0.05) {
      ctx.translate(Math.sin(simTime * 127) * shakeAmp, Math.cos(simTime * 171) * shakeAmp * 0.7);
    }
    drawDust();
    drawGlobe();
    updateWireScreen();
    drawWires();
    drawBodies();
    drawEffects();
    ctx.restore();
    drawLabels();
    drawTargetBrackets();
  }

  function updateCamera(dt) {
    if (FREEZE || state.dragging || state.reduced) return;
    if (camPause > 0) {
      camPause -= dt;
      return;
    }
    cam.yaw += dt * 0.021;
  }

  function update(dt) {
    updateCamera(dt);
    updateEffects(dt);
    updateBodies(dt);
    if (shakeAmp > 0.001) shakeAmp *= Math.exp(-dt * 5.6);
    else shakeAmp = 0;
    if (!bootPlayed && simTime > 0.9) {
      bootPlayed = true;
      playCurrent();
    }
    if (state.reel) updateReel();
    if (toastUntil > 0 && simTime > toastUntil) {
      toastEl.classList.remove('show');
      toastUntil = 0;
    }
    uiAccum += dt;
    if (uiAccum >= 1 / 30) {
      uiAccum = 0;
      syncLiveUI();
    }
  }

  function frame(now) {
    if (!running) return;
    if (!lastTime) lastTime = now;
    const rawDt = Math.min(0.05, Math.max(0, (now - lastTime) / 1000));
    lastTime = now;
    const dt = rawDt * (state.slow ? 0.35 : 1);
    simTime += dt;
    update(dt);
    render();
    requestAnimationFrame(frame);
  }

  // ── freeze / debug path ───────────────────────────────────────────────
  function finishFreeze() {
    // deterministic stepping so a still can be compared across runs
    const steps = Math.ceil(FREEZE_T * 120);
    for (let i = 0; i < steps; i++) {
      const dt = 1 / 120;
      simTime += dt;
      update(dt);
    }
    syncLiveUI();
    render();
    running = false;
    window.__MOTION_LAB_READY__ = true;
  }

  // ── init ──────────────────────────────────────────────────────────────
  resize();
  buildLibrary();
  bindUI();
  syncSelectionUI();

  if (params.has('app')) state.focusApp = clamp(parseInt(params.get('app'), 10) || 0, 0, apps.length - 1);
  if (params.has('domain')) state.focusDomain = clamp(parseInt(params.get('domain'), 10) || 0, 0, domains.length - 1);
  syncSelectionUI();

  if (FREEZE) {
    running = true;
    rebuildCamera();
    playCurrent();
    finishFreeze();
  } else {
    requestAnimationFrame(frame);
  }

  // small public surface for local probing / screenshot automation
  window.MOTION_LAB = {
    state,
    studies: STUDIES,
    bodies,
    apps,
    domains,
    effects: () => effects.map((e) => ({ cat: e.cat, study: e.study.id, body: e.body.name, age: e.age, progress: e.progress })),
    play(cat, idx, target) {
      if (cat) state.cat = cat;
      if (idx != null) state.idx = clamp(idx, 0, 3);
      if (target) state.target = target;
      syncSelectionUI();
      playCurrent();
    },
    playOn(name) {
      const b = bodies.find((x) => x.id === name || x.name === name);
      if (b) playOnBody(b);
    },
    screenOf(name) {
      const b = bodies.find((x) => x.id === name || x.name === name);
      if (!b) return null;
      const pr = project(bodyVisual(b));
      return { body: b.name, presence: b.presence, clip: b.clip, warp: b.warp, recoil: b.recoil, screen: pr ? { x: pr.x, y: pr.y, s: pr.s, z: pr.z } : null };
    },
    setCamera(yaw, pitch, dist) {
      if (yaw != null) cam.yaw = yaw;
      if (pitch != null) cam.pitch = pitch;
      if (dist != null) cam.dist = dist;
      render();
    },
    render,
    simTime: () => simTime,
  };
})();
