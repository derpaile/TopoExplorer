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
        texture2d<uint, access::read> landcover [[texture(0)]],
        texture2d<float, access::sample> elevation [[texture(1)]],
        constant float4 *palette [[buffer(0)]],
        constant ReliefUniforms &relief [[buffer(1)]])
    {
        uint landWidth = landcover.get_width();
        uint landHeight = landcover.get_height();
        uint2 classPosition = min(
            uint2(in.uv * float2(landWidth, landHeight)),
            uint2(landWidth - 1, landHeight - 1)
        );
        uint classIndex = min(landcover.read(classPosition).r, 7u);
        float4 base = palette[classIndex];
        if (classIndex == 0u) {
            return float4(base.rgb, 1.0);
        }

        // Ein Pixel Überlappung je Kachel hält die lineare Reliefabtastung
        // und die zentralen Ableitungen über Kachelgrenzen hinweg identisch.
        constexpr sampler elevationSampler(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 elevationPosition = float2(1.5) + in.uv * float2(landWidth - 1, landHeight - 1);
        float left = elevation.sample(elevationSampler, elevationPosition + float2(-1.0, 0.0)).r;
        float right = elevation.sample(elevationSampler, elevationPosition + float2(1.0, 0.0)).r;
        float up = elevation.sample(elevationSampler, elevationPosition + float2(0.0, -1.0)).r;
        float down = elevation.sample(elevationSampler, elevationPosition + float2(0.0, 1.0)).r;

        float dzdx = (right - left) * 0.5 * relief.exaggeration;
        float dzdy = (down - up) * 0.5 * relief.exaggeration;
        float3 normal = normalize(float3(-dzdx, -dzdy, 1.0));

        constexpr float altitude = 0.6108652382;
        constexpr float azimuthOne = 5.4977871438;
        constexpr float azimuthTwo = 2.3561944902;
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

        float shadeOne = clamp(dot(normal, lightOne) * 0.5 + 0.5, 0.0, 1.0);
        float shadeTwo = clamp(dot(normal, lightTwo) * 0.5 + 0.5, 0.0, 1.0);
        float shade = clamp(max(shadeOne * 1.2, shadeTwo * 0.7), 0.0, 1.0);
        shade = pow(shade, max(relief.contrast, 0.01));
        float reliefGray = clamp((1.0 - shade) + relief.ambient, 0.0, 1.0);
        float3 composed = mix(base.rgb, float3(reliefGray), relief.opacity);
        return float4(composed, 1.0);
    }
    """#
}
