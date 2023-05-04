precision mediump float;

varying highp vec2 v_posPixels;
varying highp vec2 v_sizePixels;
varying highp vec2 v_uv;

uniform sampler2D u_sampler;
uniform vec4 u_color;
uniform float u_cornerRadius;

float roundedBoxSDF(vec2 center, vec2 size, float radius) {
    return length(max(abs(center) - size + radius, 0.0)) - radius;
}

void main()
{
    float edgeSoftness = 1.0;
    float distance = roundedBoxSDF(
        gl_FragCoord.xy - v_posPixels - v_sizePixels / 2.0,
        v_sizePixels / 2.0,
        u_cornerRadius
    );
    float smoothedAlpha = 1.0 - smoothstep(0.0, edgeSoftness * 2.0, distance);

    gl_FragColor = texture2D(u_sampler, v_uv) * u_color;
    gl_FragColor.a *= smoothedAlpha;
}
