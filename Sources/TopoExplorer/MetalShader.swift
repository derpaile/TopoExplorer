enum MetalShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct TileVertex {
        float2 position;
        float2 uv;
    };

    struct RasterOut {
        float4 position [[position]];
        float2 uv [[center_no_perspective]];
    };

    struct ReliefUniforms {
        float opacity;
        float exaggeration;
        float contrast;
        float ambient;
        float azimuth;
        float padding0;
        float padding1;
        float padding2;
    };

    struct ComparisonUniforms {
        uint mode;
        float splitPosition;
        float drawableWidth;
        float padding;
    };

    struct ThematicUniforms {
        uint active;
        uint replacesBase;
        float opacity;
        float padding;
        float4 uv;
    };

    struct VectorSegment {
        short2 start;
        short2 end;
        uint attributes;
    };

    struct VectorUniforms {
        // Tile origin (top-left), tile span and quantization extent in view points.
        float4 tile;
        // Viewport width and height in points.
        float4 viewport;
        uint layer;
        uint pass;
        uint zoom;
        uint kindMask;
    };

    struct VectorOut {
        float4 position [[position]];
        float4 color;
    };

    vertex RasterOut tileVertex(
        uint vertexID [[vertex_id]],
        constant TileVertex *vertices [[buffer(0)]])
    {
        RasterOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.uv = vertices[vertexID].uv;
        return out;
    }

    fragment float4 tileFragment(
        RasterOut in [[stage_in]],
        texture2d<uint, access::read> landcover2015 [[texture(0)]],
        texture2d<float, access::sample> elevation [[texture(1)]],
        texture2d<uint, access::read> landcover2020 [[texture(2)]],
        texture2d<uint, access::read> thematicRaster [[texture(3)]],
        constant float4 *palette [[buffer(0)]],
        constant ReliefUniforms &relief [[buffer(1)]],
        constant ComparisonUniforms &comparison [[buffer(2)]],
        constant float4 *thematicPalette [[buffer(3)]],
        constant ThematicUniforms &thematic [[buffer(4)]])
    {
        uint landWidth = landcover2015.get_width();
        uint landHeight = landcover2015.get_height();
        uint2 classPosition = min(
            uint2(in.uv * float2(landWidth, landHeight)),
            uint2(landWidth - 1, landHeight - 1)
        );
        bool use2020 = comparison.mode == 1u
            || (comparison.mode == 2u
                && in.position.x >= comparison.splitPosition * comparison.drawableWidth);
        uint classIndex = min(
            use2020 ? landcover2020.read(classPosition).r : landcover2015.read(classPosition).r,
            39u
        );
        float4 base = palette[classIndex];
        bool muted = base.a < 0.5;
        float luminance = dot(base.rgb, float3(0.2126, 0.7152, 0.0722));
        float3 baseColor = muted
            ? mix(float3(0.58, 0.60, 0.57), float3(luminance), 0.18)
            : base.rgb;
        float2 thematicUV = thematic.uv.xy + in.uv * thematic.uv.zw;
        uint2 thematicPosition = min(
            uint2(thematicUV * float2(thematicRaster.get_width(), thematicRaster.get_height())),
            uint2(thematicRaster.get_width() - 1, thematicRaster.get_height() - 1)
        );
        uint thematicIndex = thematic.active == 0u
            ? 0u : thematicRaster.read(thematicPosition).r;
        float thematicAmount = thematic.replacesBase != 0u
            ? 1.0 : clamp(thematic.opacity, 0.0, 1.0);
        float3 mapColor = thematicIndex == 0u
            ? baseColor
            : mix(baseColor, thematicPalette[thematicIndex].rgb, thematicAmount);
        if (classIndex == 0u) {
            return float4(mapColor, 1.0);
        }

        // Ein Pixel Überlappung je Kachel hält die lineare Reliefabtastung
        // und die zentralen Ableitungen über Kachelgrenzen hinweg identisch.
        constexpr sampler elevationSampler(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 elevationInterior = float2(
            elevation.get_width() - 2,
            elevation.get_height() - 2
        );
        float2 elevationPosition = float2(1.5) + in.uv * (elevationInterior - 1.0);
        float left = elevation.sample(elevationSampler, elevationPosition + float2(-1.0, 0.0)).r;
        float right = elevation.sample(elevationSampler, elevationPosition + float2(1.0, 0.0)).r;
        float up = elevation.sample(elevationSampler, elevationPosition + float2(0.0, -1.0)).r;
        float down = elevation.sample(elevationSampler, elevationPosition + float2(0.0, 1.0)).r;

        float dzdx = (right - left) * 0.5 * relief.exaggeration;
        float dzdy = (down - up) * 0.5 * relief.exaggeration;
        float3 normal = normalize(float3(-dzdx, -dzdy, 1.0));

        constexpr float altitude = 0.6108652382;
        float azimuthOne = relief.azimuth;
        float azimuthTwo = fmod(relief.azimuth + M_PI_F, 2.0 * M_PI_F);
        float3 lightOne = normalize(float3(
            sin(azimuthOne) * cos(altitude),
            -cos(azimuthOne) * cos(altitude),
            sin(altitude)
        ));
        float3 lightTwo = normalize(float3(
            sin(azimuthTwo) * cos(altitude),
            -cos(azimuthTwo) * cos(altitude),
            sin(altitude)
        ));

        // Gegenlicht entfernt die konstante Helligkeit ebener Flächen. Das
        // Reliefsignal ist dadurch exakt um neutrales 50-%-Grau zentriert.
        float directionalShade = (dot(normal, lightOne) - dot(normal, lightTwo))
            / (2.0 * cos(altitude));
        float shapedShade = tanh(directionalShade * max(relief.contrast, 0.01) * 1.35);
        float reliefTone = 0.5 + 0.5 * shapedShade;
        reliefTone = mix(reliefTone, 1.0, clamp(relief.ambient, 0.0, 1.0));

        // Geologie und Substrat werden vor dem Relief zusammengesetzt. Dadurch
        // bleibt das Gelände auch bei einer vollständig ersetzten Basiskarte sichtbar.
        float3 softLight;
        if (reliefTone <= 0.5) {
            softLight = (1.0 - 2.0 * reliefTone) * mapColor * mapColor
                + 2.0 * reliefTone * mapColor;
        } else {
            softLight = 2.0 * (1.0 - reliefTone) * mapColor
                + (2.0 * reliefTone - 1.0) * sqrt(max(mapColor, float3(0.0)));
        }
        float3 composed = mix(mapColor, softLight, clamp(relief.opacity, 0.0, 1.0));
        return float4(composed, 1.0);
    }

    float vectorCoreWidth(uint layer, uint kind)
    {
        if (layer == 1u) {
            return kind <= 1u ? 2.8 : (kind <= 3u ? 2.1 : (kind <= 5u ? 1.5 : 1.0));
        }
        if (layer == 2u) return kind <= 2u ? 1.5 : 1.0;
        if (layer == 3u) {
            return kind == 1u ? 1.45 : (kind == 2u ? 1.05 : (kind == 3u ? 0.52 : 0.38));
        }
        return kind == 1u ? 2.0 : (kind == 2u ? 1.4 : 0.8);
    }

    float4 vectorCoreColor(uint layer, uint kind)
    {
        if (layer == 1u) {
            if (kind == 1u) return float4(0.96, 0.84, 0.68, 0.96);
            if (kind <= 3u) return float4(0.95, 0.76, 0.47, 0.92);
            return float4(0.16, 0.12, 0.10, 0.82);
        }
        if (layer == 2u) return float4(0.05, 0.04, 0.05, 0.86);
        if (layer == 3u) {
            float alpha = kind == 1u ? 0.76 : (kind == 2u ? 0.70 : (kind == 3u ? 0.70 : 0.58));
            return float4(0.04, 0.36, 0.68, alpha);
        }
        return float4(0.96, 0.96, 0.94, kind <= 2u ? 0.72 : 0.42);
    }

    float4 vectorCasingColor(uint layer, uint kind)
    {
        if (layer == 1u) {
            return kind == 1u
                ? float4(0.70, 0.25, 0.23, 0.86)
                : float4(0.76, 0.49, 0.19, 0.82);
        }
        if (layer == 2u) return float4(0.70, 0.25, 0.23, 0.86);
        return float4(0.05, 0.05, 0.05, 0.32);
    }

    vertex VectorOut vectorVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device VectorSegment *segments [[buffer(0)]],
        constant VectorUniforms &uniforms [[buffer(1)]])
    {
        constexpr uint endpoint[6] = {0u, 0u, 1u, 0u, 1u, 1u};
        constexpr float side[6] = {1.0, -1.0, -1.0, 1.0, -1.0, 1.0};
        VectorSegment segment = segments[instanceID];
        uint kind = segment.attributes & 0xffu;
        uint minimumZoom = (segment.attributes >> 8) & 0xffu;
        if (uniforms.layer == 3u) {
            // Das dichte Kleinfließgewässernetz darf den grünen Untergrund
            // in mittleren Maßstäben nicht flächig blau überdecken.
            if (kind == 3u) minimumZoom = max(minimumZoom, 5u);
            if (kind >= 4u) minimumZoom = max(minimumZoom, 6u);
        }
        float scale = uniforms.tile.z / uniforms.tile.w;
        float2 a = uniforms.tile.xy + float2(segment.start) * scale;
        float2 b = uniforms.tile.xy + float2(segment.end) * scale;
        bool isPoint = all(segment.start == segment.end);
        float2 delta = b - a;
        float segmentLength = max(length(delta), 0.0001);
        float width = vectorCoreWidth(uniforms.layer, kind);
        float4 color = vectorCoreColor(uniforms.layer, kind);
        if (uniforms.pass == 0u) {
            width += (uniforms.layer == 1u || uniforms.layer == 2u) ? 0.9 : 1.4;
            color = vectorCasingColor(uniforms.layer, kind);
        }
        float2 normal = float2(-delta.y, delta.x) / segmentLength * (width * 0.5);
        constexpr float2 pointCorner[6] = {
            float2(-1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0),
            float2(-1.0, -1.0), float2(1.0, 1.0), float2(1.0, -1.0)
        };
        float2 point = isPoint
            ? a + pointCorner[vertexID] * max(width, 2.0)
            : (endpoint[vertexID] == 0u ? a : b) + normal * side[vertexID];
        float2 clip = float2(
            point.x / uniforms.viewport.x * 2.0 - 1.0,
            1.0 - point.y / uniforms.viewport.y * 2.0
        );
        VectorOut out;
        bool kindEnabled = (uniforms.kindMask & (1u << kind)) != 0u;
        out.position = minimumZoom <= uniforms.zoom && kindEnabled
            ? float4(clip, 0.0, 1.0)
            : float4(2.0, 2.0, 0.0, 1.0);
        out.color = color;
        return out;
    }

    fragment float4 vectorFragment(VectorOut in [[stage_in]])
    {
        return in.color;
    }
    """#
}
