#include "common.glsl"

layout(binding = 0) uniform sampler2D frame;
uniform bool linear_blending;
layout(location = 0) out vec4 out_FragColor;

void main() {
    vec4 color = texelFetch(frame, ivec2(gl_FragCoord.xy), 0);

    // Sampling an sRGB render target decodes its linear-premultiplied RGB.
    // GDK instead needs sRGB-premultiplied bytes. Encode the straight color,
    // then premultiply again, writing to a non-sRGB export attachment.
    if (linear_blending && color.a > 0.0) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
    }

    out_FragColor = color.a > 0.0 ? color : vec4(0.0);
}
