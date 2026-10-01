#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 首页动态背景：透视时空网格被星球压出凹陷 + 深色星球 + 一圈圈的彩色行星环。
// 坐标以屏幕宽度为单位，原点在星球中心，y 向下。

namespace {

float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float3 rainbow(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}

/// 网格线强度：约 1 像素的线芯 + 一层柔光。aa 是一个像素对应的网格单位长度；线太密时淡出，避免摩尔纹
float gridLine(float2 cell, float aa) {
    float2 d = 0.5 - abs(fract(cell) - 0.5);
    float m = min(d.x, d.y);
    float core = 1.0 - smoothstep(0.0, aa * 1.4, m);
    float glow = exp(-m / max(aa * 5.0, 1e-4)) * 0.35;
    return (core + glow) * saturate(1.25 - aa * 4.0);
}

}

[[ stitchable ]] half4 aetherSpace(float2 pos, half4 color, float2 size, float2 center, float time, float mono) {
    float s = size.x;
    float2 uv = (pos - center) / s;
    float r = length(uv);
    float rp = 0.12;    // 星球半径

    // ---- 深空 + 星云
    float3 col = float3(0.012, 0.010, 0.035);
    float2 n1 = uv - float2(-0.45, -0.75);
    float2 n2 = uv - float2(0.55, 0.9);
    col += 0.11 * rainbow(0.62 + uv.x * 0.3 + time * 0.012) * exp(-dot(n1, n1) * 2.6);
    col += 0.08 * rainbow(0.12 + uv.y * 0.2 - time * 0.01) * exp(-dot(n2, n2) * 2.2);

    // ---- 星空
    float2 sp = uv * 40.0;
    float2 id = floor(sp);
    float h = hash21(id);
    if (h > 0.93) {
        float2 o = float2(hash21(id + 1.3), hash21(id + 7.1)) - 0.5;
        float d = length(fract(sp) - 0.5 - o * 0.6);
        float twinkle = 0.6 + 0.4 * sin(time * (1.0 + h * 3.0) + h * 40.0);
        col += float3(0.9, 0.92, 1.0) * smoothstep(0.09, 0.0, d) * twinkle * (h - 0.93) * 14.0;
    }

    // ---- 透视时空网格：被星球的质量拉出凹陷，并缓慢旋转
    float horizonY = -0.6;
    float camH = 0.3;
    if (uv.y > horizonY + 0.004) {
        float depth = camH / (uv.y - horizonY);
        float depth0 = camH / (-horizonY);
        float2 P = float2(uv.x * depth, depth - depth0);
        float pr = length(P);
        float well = 0.24 / (pr + 0.11);
        float ang = time * 0.045 + well * 0.9;
        float2x2 rot = float2x2(cos(ang), sin(ang), -sin(ang), cos(ang));
        float2 Q = rot * (P * (1.0 + well));
        float scale = 5.5;
        float aa = scale * (1.0 + well) * depth * (1.0 + depth / camH) / s;
        float line = gridLine(Q * scale, aa);
        float far = saturate((uv.y - horizonY) * 5.0);
        float near = saturate(1.7 - pr * 0.3);
        float ripple = 0.62 + 0.38 * sin(pr * 9.0 - time * 1.4);     // 引力波
        float glow = 0.32 + 1.5 * well;
        float3 lc = rainbow(atan2(P.y, P.x) / 6.28318 + 0.6 + time * 0.02 + pr * 0.15);
        col += lc * line * far * near * ripple * glow * 0.6;
    }

    // ---- 星球在网格上的光晕
    col += float3(0.48, 0.36, 1.0) * 0.35 * exp(-max(r - rp, 0.0) * 7.0);

    // ---- 行星环：水平的扁平光环，一圈圈同心条纹，越靠内转得越快，一侧更亮
    float2 dp = float2(uv.x, uv.y / 0.27);
    float rd = max(length(dp), 1e-4);
    float da = atan2(dp.y, dp.x);
    float band = smoothstep(rp * 1.25, rp * 1.5, rd) * (1.0 - smoothstep(rp * 2.1, rp * 3.15, rd));
    float swirl = 0.55 + 0.45 * sin(da * 5.0 - time * 2.2 * rp / rd + log(rd) * 14.0);
    float doppler = 0.5 + 0.5 * cos(da + 0.5);
    float3 ringCol = mix(float3(1.0, 0.92, 0.75), rainbow(rd / rp * 0.22 + time * 0.03 + 0.05), saturate((rd / rp - 1.3) * 0.6));
    float3 belt = ringCol * band * swirl * (0.35 + 0.9 * doppler);
    bool front = dp.y > 0.0;

    // ---- 星球：左上受光的深靛色球体 + 彩色大气边缘
    float inside = smoothstep(rp, rp * 0.985, r);
    if (!front) col += belt * (1.0 - inside);
    if (inside > 0.0) {
        float2 q = uv / rp;
        float nz = sqrt(max(0.0, 1.0 - dot(q, q)));
        float3 n = float3(q.x, q.y, nz);
        float3 L = normalize(float3(-0.55, -0.6, 0.6));
        float diff = max(dot(n, L), 0.0);
        float3 base = mix(float3(0.02, 0.022, 0.06), float3(0.27, 0.29, 0.55), pow(diff, 1.4));
        base += float3(1.0) * pow(max(dot(reflect(-L, n), float3(0, 0, 1)), 0.0), 24.0) * 0.18;
        col = mix(col, base, inside);
    }
    float rimAng = atan2(uv.y, uv.x);
    float lit = 0.3 + 0.7 * max(0.0, cos(rimAng + 2.35));
    col += rainbow(rimAng / 6.28318 + 0.55) * exp(-abs(r - rp) * 120.0) * 0.9 * lit;
    col += rainbow(rimAng / 6.28318 + 0.6) * exp(-max(r - rp, 0.0) * 30.0) * 0.25 * lit * step(rp, r);
    if (front) col += belt;

    // ---- 暗角、单色（无痕）、色调映射
    float2 v = (pos / size - 0.5) * float2(1.0, size.y / size.x);
    col *= 1.0 - 0.45 * smoothstep(0.5, 1.4, length(v));
    if (mono > 0.5) {
        float l = dot(col, float3(0.299, 0.587, 0.114));
        col = float3(l) * float3(0.92, 0.95, 1.0);
    }
    col = col / (1.0 + col * 0.35);
    return half4(half3(col), 1.0h);
}
