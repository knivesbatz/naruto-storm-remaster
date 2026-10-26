/*
	NS_Remaster.fx - UI-aware "modern remaster" post-processing for
	NARUTO: Ultimate Ninja STORM (PC, D3D11) on ReShade 5/6.

	Technique order (top to bottom in ReShade):
	  NS_Begin        (required)  normals/depth prep, HUD + scene detection, original-frame copy
	  NS_AntiAliasing (optional)  directional edge AA
	  NS_RTGI         (optional)  GTAO ambient occlusion + simulated one-bounce indirect light
	  NS_Reflections  (optional)  screen-space reflections on upward-facing surfaces
	  NS_LightShafts  (optional)  radial light shafts from bright sky / distant haze
	  NS_Bloom        (optional)  HUD-masked 6-level bloom
	  NS_Sharpen      (optional)  contrast-adaptive, outline-safe sharpening
	  NS_Finish       (required)  rim light, cel bands + ink lines, fog, colour grade, vignette,
	                              HUD/menu restore, debug views

	"RTGI" here is a screen-space approximation (horizon-based AO + colour bleeding).
	It is NOT hardware ray tracing and cannot see anything off-screen.

	All code in this file is original to this project (see LICENSE).
*/

#ifndef NS_EFFECT_DIV
	#define NS_EFFECT_DIV 2 // resolution divider for AO/GI/SSR buffers: 2 = half res, 3 = third res (faster)
#endif

#define NS_W BUFFER_WIDTH
#define NS_H BUFFER_HEIGHT
#define NS_EW (BUFFER_WIDTH / NS_EFFECT_DIV)
#define NS_EH (BUFFER_HEIGHT / NS_EFFECT_DIV)
static const float2 PIX = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
static const float2 EPIX = float2(1.0 / NS_EW, 1.0 / NS_EH);
static const float ASPECT = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
static const float PI = 3.14159265;

// ----------------------------------------------------------------------------
// UI
// ----------------------------------------------------------------------------

uniform float DepthFar < ui_category = "Depth (advanced)"; ui_type = "drag"; ui_min = 100.0; ui_max = 5000.0; ui_label = "Far plane"; ui_tooltip = "Depth linearisation constant. 1000 matches this game."; > = 1000.0;
uniform float FovY < ui_category = "Depth (advanced)"; ui_type = "slider"; ui_min = 30.0; ui_max = 90.0; ui_label = "Vertical FOV"; ui_tooltip = "Used to rebuild 3D positions for AO and reflections."; > = 50.0;

uniform bool DepthDelay < ui_category = "Depth (advanced)"; ui_label = "Delay depth by one frame"; ui_tooltip = "This game shows the image one frame after its depth. Keep ON, otherwise outlines, AO and rim light trail moving characters (ghost doubles)."; > = true;

uniform bool HudProtect < ui_category = "HUD / Menus"; ui_label = "Protect HUD"; ui_tooltip = "Keeps health bars, portraits, item wheel and prompts free of AO, bloom, reflections and sharpening."; > = true;
uniform bool MenuBypass < ui_category = "HUD / Menus"; ui_label = "Bypass menus and videos"; ui_tooltip = "Full-screen menus and pre-rendered videos have no 3D depth: show them untouched."; > = true;
uniform float HudFeather < ui_category = "HUD / Menus"; ui_type = "slider"; ui_min = 0.0; ui_max = 0.08; ui_label = "HUD mask softness"; > = 0.03;
uniform float4 HudCustomRect < ui_category = "HUD / Menus"; ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.005; ui_label = "Extra protected box (x0 y0 x1 y1)"; ui_tooltip = "Optional extra rectangle in 0-1 screen units, e.g. for subtitles. All zero = off."; > = float4(0, 0, 0, 0);

uniform int AAQuality < ui_category = "Anti-aliasing"; ui_type = "combo"; ui_items = "Fast\0Quality\0"; ui_label = "AA quality"; > = 1;
uniform float AASubpix < ui_category = "Anti-aliasing"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Sub-pixel smoothing"; ui_tooltip = "Higher removes more shimmer on foliage but softens texture detail."; > = 0.5;

uniform int GIQuality < ui_category = "RTGI (simulated)"; ui_type = "combo"; ui_items = "Low\0Medium\0High\0Ultra\0"; ui_label = "AO/GI quality"; > = 1;
uniform float AOStrength < ui_category = "RTGI (simulated)"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.5; ui_label = "Ambient occlusion"; > = 1.1;
uniform float AORadius < ui_category = "RTGI (simulated)"; ui_type = "slider"; ui_min = 0.5; ui_max = 20.0; ui_label = "AO radius"; > = 12.0;
uniform float GIStrength < ui_category = "RTGI (simulated)"; ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_label = "Indirect light (colour bounce)"; > = 1.0;
uniform float AOFadeEnd < ui_category = "RTGI (simulated)"; ui_type = "slider"; ui_min = 0.05; ui_max = 1.0; ui_label = "Fade-out distance"; > = 0.5;

uniform int SSRSteps < ui_category = "Reflections"; ui_type = "slider"; ui_min = 8; ui_max = 48; ui_label = "Ray steps"; > = 20;
uniform float SSRStrength < ui_category = "Reflections"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Reflection strength"; > = 0.6;
uniform float SSRWetness < ui_category = "Reflections"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Wet / glossy look"; ui_tooltip = "Raises reflectivity when looking straight down. 0 = only grazing-angle reflections."; > = 0.15;
uniform float SSRGrassReject < ui_category = "Reflections"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Skip grass/foliage"; > = 0.9;

uniform float ShaftStrength < ui_category = "Light shafts"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Shaft intensity"; > = 0.8;
uniform float ShaftLength < ui_category = "Light shafts"; ui_type = "slider"; ui_min = 0.1; ui_max = 1.0; ui_label = "Shaft length"; > = 0.6;
uniform int ShaftSamples < ui_category = "Light shafts"; ui_type = "slider"; ui_min = 8; ui_max = 48; ui_label = "Samples"; > = 24;
uniform float ShaftThreshold < ui_category = "Light shafts"; ui_type = "slider"; ui_min = 0.3; ui_max = 0.95; ui_label = "Sky brightness threshold"; > = 0.72;
uniform float3 ShaftTint < ui_category = "Light shafts"; ui_type = "color"; ui_label = "Tint"; > = float3(1.0, 0.92, 0.78);

uniform float BloomIntensity < ui_category = "Bloom"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Bloom intensity"; > = 1.0;
uniform float BloomThreshold < ui_category = "Bloom"; ui_type = "slider"; ui_min = 0.3; ui_max = 1.0; ui_label = "Threshold"; > = 0.56;
uniform float BloomSoftness < ui_category = "Bloom"; ui_type = "slider"; ui_min = 0.05; ui_max = 0.5; ui_label = "Glow softness"; ui_tooltip = "Higher lets mid-bright areas glow gently (anime diffusion look)."; > = 0.25;
uniform float FXGlow < ui_category = "Bloom"; ui_type = "slider"; ui_min = 0.0; ui_max = 6.0; ui_label = "Jutsu / FX glow"; ui_tooltip = "Extra glow for very bright, saturated colours: chakra, fire, lightning, Rasengan."; > = 2.5;
uniform float BloomRadius < ui_category = "Bloom"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Wide glow"; ui_tooltip = "Weight of the large, soft glow levels."; > = 0.45;
uniform float FlareIntensity < ui_category = "Lens flare"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Lens flare ghosts"; ui_tooltip = "Colour-fringed lens reflections from bright jutsu and the sun (mirrored through the screen centre)."; > = 0.35;
uniform float FlareHalo < ui_category = "Lens flare"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Halo ring"; > = 0.25;
uniform float StreakIntensity < ui_category = "Lens flare"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Anamorphic streaks"; ui_tooltip = "Horizontal light streaks from bright points (cinema / anime lens look)."; > = 0.35;
uniform float3 StreakTint < ui_category = "Lens flare"; ui_type = "color"; ui_label = "Streak tint"; > = float3(0.55, 0.75, 1.0);
uniform float3 BloomTint < ui_category = "Bloom"; ui_type = "color"; ui_label = "Tint"; > = float3(1.0, 0.95, 0.9);

uniform float SharpStrength < ui_category = "Sharpen"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.5; ui_label = "Sharpness"; > = 1.3;
uniform float SharpDetail < ui_category = "Sharpen"; ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_label = "Detail boost (wide)"; ui_tooltip = "Second, wider sharpening for textures (rock, ground, cloth). Overshoot is capped so outlines do not ring."; > = 2.2;
uniform float SharpFarFade < ui_category = "Sharpen"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Reduce on distant scenery"; > = 0.3;

uniform float RimStrength < ui_category = "Rim light"; ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_label = "Rim light"; ui_tooltip = "Anime-style glow on the edges of characters and objects in front of a bright background."; > = 0.8;
uniform float RimWidth < ui_category = "Rim light"; ui_type = "slider"; ui_min = 1.0; ui_max = 6.0; ui_label = "Rim width (pixels)"; > = 3.0;
uniform float3 RimTint < ui_category = "Rim light"; ui_type = "color"; ui_label = "Rim tint"; > = float3(1.0, 0.95, 0.85);

uniform bool FogEnable < ui_category = "Fog"; ui_label = "Atmospheric fog"; > = true;
uniform float FogDensity < ui_category = "Fog"; ui_type = "slider"; ui_min = 0.0; ui_max = 5.0; ui_label = "Density"; > = 0.8;
uniform float FogStart < ui_category = "Fog"; ui_type = "slider"; ui_min = 0.0; ui_max = 0.95; ui_label = "Start distance"; ui_tooltip = "In this game the arena walls sit around 0.7-0.8 of the depth range."; > = 0.55;
uniform float FogMax < ui_category = "Fog"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Maximum opacity"; > = 0.22;
uniform float FogAutoColor < ui_category = "Fog"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Match sky colour"; > = 0.7;
uniform float3 FogColor < ui_category = "Fog"; ui_type = "color"; ui_label = "Fog colour"; > = float3(0.72, 0.8, 0.9);
uniform float FogSunGlow < ui_category = "Fog"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Sun-side glow"; > = 0.4;

uniform bool GradeEnable < ui_category = "Colour grade"; ui_label = "Colour grading"; > = true;
uniform float AdaptExposure < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Adaptive exposure"; ui_tooltip = "Eases exposure toward a balanced brightness: lifts dark/stormy maps, calms very bright ones."; > = 0.5;
uniform float AdaptVibrance < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Adaptive vibrance"; ui_tooltip = "Extra colour boost on dull, grey scenes; backs off on already colourful ones."; > = 0.6;
uniform float FilmicStrength < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Filmic tone curve"; ui_tooltip = "ACES-style toe and shoulder on brightness only (colours keep their vibrancy)."; > = 0.7;
uniform float Exposure < ui_category = "Colour grade"; ui_type = "slider"; ui_min = -1.0; ui_max = 1.0; ui_label = "Exposure"; ui_tooltip = "Scene exposure. Jutsu/chakra light is exempt so effects still shine."; > = -0.9;
uniform float Contrast < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.7; ui_max = 2.0; ui_label = "Filmic contrast"; > = 1.5;
uniform float ShadowLift < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 0.1; ui_label = "Shadow detail"; ui_tooltip = "Keeps blacks from crushing after contrast/AO."; > = 0.008;
uniform float HighlightRolloff < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Highlight roll-off"; > = 0.8;
uniform float Saturation < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_label = "Saturation"; > = 1.15;
uniform float Vibrance < ui_category = "Colour grade"; ui_type = "slider"; ui_min = -0.5; ui_max = 1.0; ui_label = "Vibrance"; ui_tooltip = "Boosts dull colours more than already-vivid ones; skin tones are protected."; > = 0.45;
uniform float Temperature < ui_category = "Colour grade"; ui_type = "slider"; ui_min = -1.0; ui_max = 1.0; ui_label = "Temperature"; > = 0.05;
uniform float3 ShadowTint < ui_category = "Colour grade"; ui_type = "color"; ui_label = "Shadow tint"; ui_tooltip = "Keep near neutral: a strong blue cast turns teal/green clothing blue."; > = float3(0.97, 0.98, 1.01);
uniform float3 HighlightTint < ui_category = "Colour grade"; ui_type = "color"; ui_label = "Highlight tint"; > = float3(1.05, 1.0, 0.93);
uniform float InkStrength < ui_category = "Manga look"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Ink lines"; ui_tooltip = "Manga-style dark lines on silhouettes (rocks, buildings, trees), matching the characters' cel outlines."; > = 0.6;
uniform float InkCrease < ui_category = "Manga look"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Crease lines"; ui_tooltip = "Extra lines where surfaces fold (rock edges, roof corners)."; > = 0.5;
uniform float InkFoliage < ui_category = "Manga look"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Ink on grass/foliage"; ui_tooltip = "Grass blades create many tiny edges; keep this low to avoid busy lines."; > = 0.2;
uniform float InkWidth < ui_category = "Manga look"; ui_type = "slider"; ui_min = 1.0; ui_max = 2.5; ui_label = "Line width (pixels)"; > = 1.5;
uniform float CelStrength < ui_category = "Manga look"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Cel shading"; ui_tooltip = "Quantises scenery shading into soft tone bands like the character shading."; > = 0.4;
uniform int CelBands < ui_category = "Manga look"; ui_type = "slider"; ui_min = 2; ui_max = 8; ui_label = "Tone bands"; > = 4;
uniform float Vignette < ui_category = "Colour grade"; ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Vignette"; > = 0.4;

uniform int DebugView < ui_category = "Debug"; ui_type = "combo"; ui_items = "Off\0Depth\0Normals\0AO + GI\0Reflections\0Light shafts\0Bloom\0HUD mask\0Scene state\0Split: original | result\0Depth/colour alignment\0"; ui_label = "Debug view"; > = 0;

uniform float FrameTime < source = "frametime"; >;

// ----------------------------------------------------------------------------
// Textures
// ----------------------------------------------------------------------------

texture BackBufferTex : COLOR;
texture DepthBufferTex : DEPTH;
sampler sBack { Texture = BackBufferTex; };
sampler sBackPt { Texture = BackBufferTex; MagFilter = POINT; MinFilter = POINT; };
sampler sDepth { Texture = DepthBufferTex; MagFilter = POINT; MinFilter = POINT; };
texture texNSDepthHist { Width = NS_W; Height = NS_H; Format = R32F; };
sampler sDepthHist { Texture = texNSDepthHist; MagFilter = POINT; MinFilter = POINT; };

texture texNSOrig { Width = NS_W; Height = NS_H; Format = RGBA8; };
sampler sOrig { Texture = texNSOrig; };

texture texNSNormDepth { Width = NS_EW; Height = NS_EH; Format = RGBA16F; };
sampler sND { Texture = texNSNormDepth; MagFilter = POINT; MinFilter = POINT; };
sampler sNDLin { Texture = texNSNormDepth; };
texture texNSHalfCol { Width = NS_EW; Height = NS_EH; Format = RGBA16F; };
sampler sHalfCol { Texture = texNSHalfCol; };

texture texNSSmall0 { Width = 128; Height = 72; Format = RGBA16F; MipLevels = 8; };
texture texNSSmall1 { Width = 128; Height = 72; Format = RGBA16F; MipLevels = 8; };
sampler sSmall0 { Texture = texNSSmall0; };
sampler sSmall1 { Texture = texNSSmall1; };
texture texNSState { Width = 1; Height = 1; Format = RGBA16F; };     // scene, battle HUD, light visibility, -
texture texNSLight { Width = 1; Height = 1; Format = RGBA16F; };     // light uv, sky rgb packed below
texture texNSSky { Width = 1; Height = 1; Format = RGBA16F; };       // average sky colour, sky coverage
texture texNSSmall2 { Width = 128; Height = 72; Format = RGBA16F; MipLevels = 8; };
sampler sSmall2 { Texture = texNSSmall2; };
texture texNSAdapt { Width = 1; Height = 1; Format = RGBA16F; };     // exposure EV, extra vibrance
texture texNSAdaptPrev { Width = 1; Height = 1; Format = RGBA16F; };
sampler sAdapt { Texture = texNSAdapt; MagFilter = POINT; MinFilter = POINT; };
sampler sAdaptPrev { Texture = texNSAdaptPrev; MagFilter = POINT; MinFilter = POINT; };
texture texNSStatePrev { Width = 1; Height = 1; Format = RGBA16F; };
texture texNSLightPrev { Width = 1; Height = 1; Format = RGBA16F; };
texture texNSSkyPrev { Width = 1; Height = 1; Format = RGBA16F; };
sampler sState { Texture = texNSState; MagFilter = POINT; MinFilter = POINT; };
sampler sLight { Texture = texNSLight; MagFilter = POINT; MinFilter = POINT; };
sampler sSky { Texture = texNSSky; MagFilter = POINT; MinFilter = POINT; };
sampler sStatePrev { Texture = texNSStatePrev; MagFilter = POINT; MinFilter = POINT; };
sampler sLightPrev { Texture = texNSLightPrev; MagFilter = POINT; MinFilter = POINT; };
sampler sSkyPrev { Texture = texNSSkyPrev; MagFilter = POINT; MinFilter = POINT; };

texture texNSGI0 { Width = NS_EW; Height = NS_EH; Format = RGBA16F; };
texture texNSGI1 { Width = NS_EW; Height = NS_EH; Format = RGBA16F; };
sampler sGI0 { Texture = texNSGI0; MagFilter = POINT; MinFilter = POINT; };
sampler sGI1 { Texture = texNSGI1; MagFilter = POINT; MinFilter = POINT; };

texture texNSSSR { Width = NS_EW; Height = NS_EH; Format = RGBA16F; };
sampler sSSR { Texture = texNSSSR; };

texture texNSShaft0 { Width = NS_W / 4; Height = NS_H / 4; Format = RGBA16F; };
texture texNSShaft1 { Width = NS_W / 4; Height = NS_H / 4; Format = RGBA16F; };
sampler sShaft0 { Texture = texNSShaft0; };
sampler sShaft1 { Texture = texNSShaft1; };

texture texNSB1 { Width = NS_W / 2; Height = NS_H / 2; Format = RGBA16F; };
texture texNSB2 { Width = NS_W / 4; Height = NS_H / 4; Format = RGBA16F; };
texture texNSB3 { Width = NS_W / 8; Height = NS_H / 8; Format = RGBA16F; };
texture texNSB4 { Width = NS_W / 16; Height = NS_H / 16; Format = RGBA16F; };
texture texNSB5 { Width = NS_W / 32; Height = NS_H / 32; Format = RGBA16F; };
texture texNSB6 { Width = NS_W / 64; Height = NS_H / 64; Format = RGBA16F; };
sampler sB1 { Texture = texNSB1; AddressU = CLAMP; AddressV = CLAMP; };
sampler sB2 { Texture = texNSB2; AddressU = CLAMP; AddressV = CLAMP; };
sampler sB3 { Texture = texNSB3; AddressU = CLAMP; AddressV = CLAMP; };
sampler sB4 { Texture = texNSB4; AddressU = CLAMP; AddressV = CLAMP; };
sampler sB5 { Texture = texNSB5; AddressU = CLAMP; AddressV = CLAMP; };
sampler sB6 { Texture = texNSB6; AddressU = CLAMP; AddressV = CLAMP; };
texture texNSFlare { Width = NS_W / 4; Height = NS_H / 4; Format = RGBA16F; };
sampler sFlare { Texture = texNSFlare; AddressU = CLAMP; AddressV = CLAMP; };

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

void PostProcessVS(uint id : SV_VertexID, out float4 pos : SV_Position, out float2 uv : TEXCOORD)
{
	uv = float2((id == 2) ? 2.0 : 0.0, (id == 1) ? 2.0 : 0.0);
	pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

float3 ToLin(float3 c) { return c * c * (c * 0.2848 + 0.7152); } // cheap sRGB -> linear (max err < 1%)
float3 ToGam(float3 c) { c = max(c, 0.0); return 1.055 * pow(c, 1.0 / 2.4) - 0.055 * saturate(c * 400.0); }
float Luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float RawDepth(float2 uv) { return DepthDelay ? tex2Dlod(sDepthHist, float4(uv, 0, 0)).x : tex2Dlod(sDepth, float4(uv, 0, 0)).x; }
float LinDepth(float d) { return d / (DepthFar - d * (DepthFar - 1.0)); } // 0 = camera, 1 = far plane
float TanHalfFov() { return tan(radians(FovY * 0.5)); }
// View space: x right, y DOWN (matches uv), z forward. Units = linear depth * DepthFar.
float3 ViewPos(float2 uv, float z) { return float3((uv * 2.0 - 1.0) * float2(ASPECT, 1.0) * TanHalfFov() * z, z); }
float2 ProjUV(float3 p) { return p.xy / (p.z * TanHalfFov() * float2(ASPECT, 1.0)) * 0.5 + 0.5; }

// HUD portraits are 3D heads drawn at linear depth < 0.001; the nearest real scenery measured in-game is > 0.03.
bool IsUiDepth(float d) { return d / (DepthFar - d * (DepthFar - 1.0)) < 0.002; }
bool IsSky(float d) { return d > 0.99999; }

static const float BAYER[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
static const float AA_STEP[8] = { 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 4.0, 8.0 };

bool Bad(float x) { return (asuint(x) & 0x7FFFFFFF) >= 0x7F800000; }
bool Bad3(float3 v) { return Bad(v.x) || Bad(v.y) || Bad(v.z); }
bool Bad4(float4 v) { return Bad3(v.xyz) || Bad(v.w); }

// Saturated yellow (~50 deg hue): Naruto's hair and similar flat-shaded yellows. Kept out of glow so they
// read as paint, not light. White-hot cores and orange/blue chakra fall outside this window.
float YellowMask(float3 g)
{
	float mx = max(g.r, max(g.g, g.b)), sat = mx - min(g.r, min(g.g, g.b));
	if (sat < 1e-3 || mx != g.r && mx != g.g) return 0.0;
	float hue = mx == g.r ? frac(((g.g - g.b) / sat) / 6.0) : ((g.b - g.r) / sat + 2.0) / 6.0;
	return saturate(1.6 - abs(hue - 0.14) * 16.0) * smoothstep(0.35, 0.55, sat / max(mx, 1e-3));
}

float Bayer4(float2 vpos)
{
	int2 p = int2(vpos) & 3;
	return (BAYER[p.y * 4 + p.x] + 0.5) / 16.0;
}
float IGN(float2 p) { return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715)))); }

float RectMask(float2 uv, float4 r)
{
	float2 d = max(r.xy - uv, uv - r.zw); // > 0 outside
	return 1.0 - smoothstep(0.0, max(HudFeather, 1e-4), max(d.x, d.y));
}

float4 State() { return tex2Dfetch(sState, int2(0, 0)); } // x scene (1 = 3D gameplay), y battle HUD, z light visibility

// HUD boxes measured in-game at 16:9 (fractions of the screen). Only used while the matching HUD is detected.
float HudRectMask(float2 uv)
{
	if (!HudProtect) return 0.0;
	float4 s = State();
	float m = 0.0;
	// Battle: player block top-left, opponent block top-right, item wheels bottom corners.
	m = max(m, RectMask(uv, float4(0.05, 0.03, 0.50, 0.31)) * s.y);
	m = max(m, RectMask(uv, float4(0.50, 0.03, 0.95, 0.31)) * s.y);
	m = max(m, RectMask(uv, float4(0.065, 0.70, 0.215, 0.97)) * s.y);
	m = max(m, RectMask(uv, float4(0.785, 0.70, 0.935, 0.97)) * s.y);
	// Free roam: portrait + bar top-left, button help along the bottom, minimap bottom-right.
	float roam = s.x * (1.0 - s.y);
	m = max(m, RectMask(uv, float4(0.06, 0.04, 0.38, 0.23)) * roam);
	m = max(m, RectMask(uv, float4(0.0, 0.88, 0.72, 0.955)) * roam);
	m = max(m, RectMask(uv, float4(0.79, 0.69, 0.935, 0.955)) * roam);
	if (any(HudCustomRect.zw > HudCustomRect.xy)) m = max(m, RectMask(uv, HudCustomRect));
	return m;
}

// ----------------------------------------------------------------------------
// NS_Begin
// ----------------------------------------------------------------------------

void PS_Prep(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 nd : SV_Target0, out float4 hc : SV_Target1)
{
	float d = RawDepth(uv);
	float z = LinDepth(d) * DepthFar;
	float3 P = ViewPos(uv, z);
	// Pick the neighbour with the smaller depth step on each axis to avoid smearing normals across silhouettes.
	float2 o = EPIX;
	float3 pl = ViewPos(uv - float2(o.x, 0), LinDepth(RawDepth(uv - float2(o.x, 0))) * DepthFar);
	float3 pr = ViewPos(uv + float2(o.x, 0), LinDepth(RawDepth(uv + float2(o.x, 0))) * DepthFar);
	float3 pu = ViewPos(uv - float2(0, o.y), LinDepth(RawDepth(uv - float2(0, o.y))) * DepthFar);
	float3 pd = ViewPos(uv + float2(0, o.y), LinDepth(RawDepth(uv + float2(0, o.y))) * DepthFar);
	float3 dx = abs(pr.z - P.z) < abs(P.z - pl.z) ? pr - P : P - pl;
	float3 dy = abs(pd.z - P.z) < abs(P.z - pu.z) ? pd - P : P - pu;
	float3 N = cross(dy, dx);
	float nl = length(N);
	// Very close geometry can give near-zero depth steps; fall back to facing the camera instead of NaN.
	N = nl > 1e-10 ? N / nl : -normalize(P + float3(0, 0, 1e-6));
	if (dot(N, P) > 0.0) N = -N;
	nd = float4(N, (IsSky(d) || IsUiDepth(d)) ? DepthFar * 2.0 : z);
	hc = float4(ToLin(tex2D(sBack, uv).rgb), 1.0);
}

float4 PS_SaveOrig(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return tex2D(sBackPt, uv); }

void PS_Small(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 o0 : SV_Target0, out float4 o1 : SV_Target1, out float4 o2 : SV_Target2)
{
	float d = RawDepth(uv);
	float3 c = ToLin(tex2Dlod(sBack, float4(uv, 0, 0)).rgb);
	float geom = (!IsSky(d) && !IsUiDepth(d)) ? 1.0 : 0.0;
	float sky = IsSky(d) ? 1.0 : 0.0;
	float src = IsSky(d) ? 1.0 : (geom > 0.0 ? smoothstep(0.75, 0.95, LinDepth(d)) * 0.5 : 0.0);
	float bright = src * pow(saturate((Luma(ToGam(c)) - ShaftThreshold) / (1.0 - ShaftThreshold)), 2.0);
	o0 = float4(geom, bright * uv, bright);
	o1 = float4(c * sky, sky);
	// Scene statistics for adaptation (HUD/UI depth excluded; centre weighted like a camera meter).
	float3 g = ToGam(c);
	float w = (IsUiDepth(d) ? 0.0 : 1.0) * (1.0 - 0.6 * saturate(length(uv - 0.5) * 1.6));
	o2 = float4(log2(Luma(c) + 1e-3) * w, (max(g.r, max(g.g, g.b)) - min(g.r, min(g.g, g.b))) * w, w, 1.0);
}

void PS_Resolve(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 st : SV_Target0, out float4 li : SV_Target1, out float4 sk : SV_Target2, out float4 ad : SV_Target3)
{
	float4 s0 = tex2Dlod(sSmall0, float4(0.5, 0.5, 0, 7));
	float4 s1 = tex2Dlod(sSmall1, float4(0.5, 0.5, 0, 7));

	// Battle HUD: the opponent portrait (top-right) is a near-depth 3D head; free roam has nothing there.
	float ui = 0.0;
	[loop] for (int y = 0; y < 6; y++)
		[loop] for (int x = 0; x < 16; x++)
			ui += IsUiDepth(RawDepth(float2(0.55 + x * 0.025, 0.04 + y * 0.04))) ? 1.0 : 0.0;

	float scene = s0.x > 0.02 ? 1.0 : 0.0;
	float battle = ui >= 2.0 ? 1.0 : 0.0;
	float lightVis = saturate(s0.w * 12.0); // needs a real bright patch (sun/clear sky), overcast skies stay near 0
	float2 lightUV = s0.w > 1e-5 ? s0.yz / s0.w : float2(0.5, 0.1);

	float4 pst = tex2Dfetch(sStatePrev, int2(0, 0));
	float4 pli = tex2Dfetch(sLightPrev, int2(0, 0));
	float4 psk = tex2Dfetch(sSkyPrev, int2(0, 0));
	float k = saturate(FrameTime / 250.0);
	float kl = saturate(FrameTime / 600.0);
	if (Bad4(pst) || Bad4(pli) || Bad4(psk)) { pst = 0; pli = float4(0.5, 0.1, 0, 0); psk = 0; }
	// Scene changes snap off fast (menu opens) and fade in slower.
	float ks = scene < pst.x ? saturate(FrameTime / 60.0) : k;
	st = float4(lerp(pst.x, scene, ks), lerp(pst.y, battle, k), lerp(pst.z, lightVis, kl), 0);
	li = float4(lerp(pli.xy, lightUV, lightVis > 0.01 ? kl : 0.0), 0, 0);
	float3 skyC = s1.w > 1e-4 ? s1.rgb / s1.w : psk.rgb;
	sk = float4(lerp(psk.rgb, skyC, kl), lerp(psk.w, s1.w, kl));

	float4 s2 = tex2Dlod(sSmall2, float4(0.5, 0.5, 0, 7));
	float avgLog = s2.x / max(s2.z, 1e-4), avgSat = s2.y / max(s2.z, 1e-4);
	// Target linear mid-grey 0.16; limited range so night scenes stay night.
	float ev = clamp(log2(0.1) - avgLog, -0.4, 0.25); // gentle both ways; the base Exposure sets the mood
	float vib = saturate((0.38 - avgSat) * 3.0);
	float4 pad = tex2Dfetch(sAdaptPrev, int2(0, 0));
	if (Bad4(pad)) pad = 0;
	float ka = saturate(FrameTime / 1200.0); // ~1 s eye adaptation
	ad = (s2.z > 1e-3 && scene > 0.5) ? float4(lerp(pad.xy, float2(ev, vib), ka), 0, 0) : pad;
}

void PS_CopyPrev(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 st : SV_Target0, out float4 li : SV_Target1, out float4 sk : SV_Target2, out float4 ad : SV_Target3)
{
	st = tex2Dfetch(sState, int2(0, 0));
	li = tex2Dfetch(sLight, int2(0, 0));
	sk = tex2Dfetch(sSky, int2(0, 0));
	ad = tex2Dfetch(sAdapt, int2(0, 0));
}

// ----------------------------------------------------------------------------
// NS_AntiAliasing - luma edge search + directional resample (FXAA-style algorithm, own implementation)
// ----------------------------------------------------------------------------

float LumaAt(float2 uv) { return Luma(tex2Dlod(sBack, float4(uv, 0, 0)).rgb); }

float4 PS_AA(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c = tex2D(sBackPt, uv);
	float m = Luma(c.rgb);
	float n = LumaAt(uv + float2(0, -PIX.y)), s = LumaAt(uv + float2(0, PIX.y));
	float e = LumaAt(uv + float2(PIX.x, 0)), w = LumaAt(uv + float2(-PIX.x, 0));
	float mx = max(max(max(n, s), max(e, w)), m);
	float mn = min(min(min(n, s), min(e, w)), m);
	float range = mx - mn;
	if (range < max(0.0312, mx * 0.125)) return c;

	float nw = LumaAt(uv - PIX), se = LumaAt(uv + PIX);
	float ne = LumaAt(uv + float2(PIX.x, -PIX.y)), sw = LumaAt(uv + float2(-PIX.x, PIX.y));

	float avg = ((n + s + e + w) * 2.0 + (nw + ne + sw + se)) / 12.0;
	float sub = smoothstep(0.0, 1.0, saturate(abs(avg - m) / range));
	sub = sub * sub * AASubpix;

	float eh = abs(n + s - 2.0 * m) * 2.0 + abs(ne + se - 2.0 * e) + abs(nw + sw - 2.0 * w);
	float ev = abs(e + w - 2.0 * m) * 2.0 + abs(ne + nw - 2.0 * n) + abs(se + sw - 2.0 * s);
	bool horz = eh >= ev;
	float stepLen = horz ? PIX.y : PIX.x;
	float l1 = horz ? n : w, l2 = horz ? s : e;
	float g1 = abs(l1 - m), g2 = abs(l2 - m);
	float localAvg, grad;
	if (g1 >= g2) { stepLen = -stepLen; localAvg = 0.5 * (l1 + m); grad = g1; }
	else { localAvg = 0.5 * (l2 + m); grad = g2; }

	float2 posB = uv + (horz ? float2(0, stepLen * 0.5) : float2(stepLen * 0.5, 0));
	float2 dir = horz ? float2(PIX.x, 0) : float2(0, PIX.y);
	int steps = AAQuality == 0 ? 4 : 8;
	float2 pN = posB - dir, pP = posB + dir;
	float eN = LumaAt(pN) - localAvg, eP = LumaAt(pP) - localAvg;
	bool doneN = abs(eN) >= grad * 0.25, doneP = abs(eP) >= grad * 0.25;
	[loop] for (int i = 1; i < steps && !(doneN && doneP); i++)
	{
		if (!doneN) { pN -= dir * AA_STEP[i]; eN = LumaAt(pN) - localAvg; doneN = abs(eN) >= grad * 0.25; }
		if (!doneP) { pP += dir * AA_STEP[i]; eP = LumaAt(pP) - localAvg; doneP = abs(eP) >= grad * 0.25; }
	}
	float dN = horz ? uv.x - pN.x : uv.y - pN.y;
	float dP = horz ? pP.x - uv.x : pP.y - uv.y;
	bool nearN = dN < dP;
	float span = dN + dP;
	bool good = ((m - localAvg) < 0.0) != (((nearN ? eN : eP)) < 0.0);
	float off = good ? 0.5 - min(dN, dP) / span : 0.0;
	off = max(off, sub);
	float2 fuv = uv + (horz ? float2(0, off * stepLen) : float2(off * stepLen, 0));
	return float4(tex2Dlod(sBack, float4(fuv, 0, 0)).rgb, c.a);
}

// ----------------------------------------------------------------------------
// NS_RTGI - GTAO-style horizon search with colour bleeding
// ----------------------------------------------------------------------------

float4 PS_GI(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 nd = tex2Dlod(sND, float4(uv, 0, 0));
	float z = nd.w;
	if (z >= DepthFar * AOFadeEnd || z <= 0.0) return float4(0, 0, 0, 1);
	float3 P = ViewPos(uv, z), N = nd.xyz, V = normalize(-P);

	int dirs = GIQuality < 2 ? 2 : (GIQuality == 2 ? 3 : 4);
	int steps = 4 + GIQuality * 2;
	float noiseA = Bayer4(vpos.xy), noiseB = IGN(vpos.xy);

	float projScale = 0.5 * NS_EH / TanHalfFov();
	float rpx = min(AORadius * projScale / z, 0.15 * NS_EH);
	if (rpx < 1.0) return float4(0, 0, 0, 1);

	float falloffRange = 0.6 * AORadius;
	float falloffMul = -1.0 / falloffRange;
	float falloffAdd = (AORadius * 0.4) / falloffRange + 1.0;

	float vis = 0.0;
	float3 gi = 0.0;
	float giW = 0.0;
	[loop] for (int d = 0; d < dirs; d++)
	{
		float ang = (d + noiseA) * PI / dirs;
		float2 omega = float2(cos(ang), sin(ang));
		float3 dir3 = float3(omega, 0.0);
		float3 ortho = dir3 - dot(dir3, V) * V;
		float3 axis = normalize(cross(ortho, V));
		float3 projN = N - axis * dot(N, axis);
		float projLen = length(projN) + 1e-5;
		float cosN = saturate(dot(projN, V) / projLen);
		float n = sign(dot(ortho, projN)) * acos(cosN);
		float hc0 = cos(n + PI * 0.5), hc1 = cos(n - PI * 0.5);
		float low0 = hc0, low1 = hc1;

		[loop] for (int s = 0; s < steps; s++)
		{
			float t = (s + noiseB) / steps;
			float2 off = omega * max(t * t * rpx, 1.0 + s) * EPIX;
			[unroll] for (int side = 0; side < 2; side++)
			{
				float2 suv = side == 0 ? uv + off : uv - off;
				float4 snd = tex2Dlod(sND, float4(suv, 0, 0));
				float3 delta = ViewPos(suv, snd.w) - P;
				float dist = max(length(delta), 1e-5);
				float3 hv = delta / dist;
				float w = saturate(dist * falloffMul + falloffAdd);
				float shc = lerp(side == 0 ? low0 : low1, clamp(dot(hv, V), -1.0, 1.0), w);
				// Colour bleeding: occluders that raise the horizon and face us reflect their light onto P.
				float prev = side == 0 ? hc0 : hc1;
				if (shc > prev && w > 0.0)
				{
					float bounce = saturate(dot(N, hv)) * saturate(dot(snd.xyz, -hv)) * w;
					gi += tex2Dlod(sHalfCol, float4(suv, 0, 0)).rgb * bounce;
				}
				giW += 1.0;
				if (side == 0) hc0 = max(hc0, shc); else hc1 = max(hc1, shc);
			}
		}
		float h0 = -acos(clamp(hc1, -1.0, 1.0)), h1 = acos(clamp(hc0, -1.0, 1.0));
		h0 = n + clamp(h0 - n, -PI * 0.5, PI * 0.5);
		h1 = n + clamp(h1 - n, -PI * 0.5, PI * 0.5);
		float sn = sin(n);
		vis += projLen * 0.25 * ((cosN + 2.0 * h0 * sn - cos(2.0 * h0 - n)) + (cosN + 2.0 * h1 * sn - cos(2.0 * h1 - n)));
	}
	vis = saturate(vis / dirs);
	if (Bad(vis) || Bad3(gi)) return float4(0, 0, 0, 1);
	float fade = saturate((DepthFar * AOFadeEnd - z) / (DepthFar * AOFadeEnd * 0.3));
	return float4(gi / max(giW, 1.0) * 2.0 * fade, lerp(1.0, vis, fade));
}

// Joint-bilateral 4x4 blur (exactly covers the 4x4 Bayer rotation pattern).
float4 BilateralGI(sampler src, float2 uv)
{
	float4 c = tex2Dlod(sND, float4(uv, 0, 0));
	float4 sum = 0.0;
	float wsum = 0.0;
	[unroll] for (int y = -2; y < 2; y++)
	[unroll] for (int x = -2; x < 2; x++)
	{
		float2 suv = uv + (float2(x, y) + 0.5) * EPIX;
		float4 snd = tex2Dlod(sND, float4(suv, 0, 0));
		float w = exp(-abs(snd.w - c.w) / (c.w * 0.03 + 1e-3)) * pow(saturate(dot(snd.xyz, c.xyz)), 8.0) + 1e-4;
		sum += tex2Dlod(src, float4(suv, 0, 0)) * w;
		wsum += w;
	}
	return sum / wsum;
}
float4 PS_GIBlur(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return BilateralGI(sGI0, uv); }

float4 UpsampleEffect(sampler src, float2 uv, float zFull)
{
	// Depth-aware upsample from the reduced-resolution buffer.
	float2 base = (floor(uv * float2(NS_EW, NS_EH) - 0.5) + 0.5) * EPIX;
	float4 sum = 0.0;
	float wsum = 0.0;
	[unroll] for (int i = 0; i < 4; i++)
	{
		float2 o = float2(i & 1, i >> 1);
		float2 suv = base + o * EPIX;
		float2 bw = 1.0 - abs((uv - suv) / EPIX);
		float w = max(bw.x * bw.y, 1e-3) / (abs(tex2Dlod(sND, float4(suv, 0, 0)).w - zFull) / (zFull * 0.02 + 1e-3) + 1e-2);
		sum += tex2Dlod(src, float4(suv, 0, 0)) * w;
		wsum += w;
	}
	return sum / wsum;
}

float4 PS_GIComposite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c = tex2D(sBackPt, uv);
	float d = RawDepth(uv);
	if (IsSky(d) || IsUiDepth(d)) return c;
	float4 g = UpsampleEffect(sGI1, uv, LinDepth(d) * DepthFar);
	if (Bad4(g)) return c;
	float3 lin = ToLin(c.rgb);
	float ao = lerp(1.0, g.a, AOStrength);
	float3 albedo = saturate(lin * 1.6);
	lin = lin * ao + g.rgb * albedo * GIStrength * (0.5 + 0.5 * ao);
	return float4(ToGam(lin), c.a);
}

// ----------------------------------------------------------------------------
// NS_Reflections
// ----------------------------------------------------------------------------

float4 PS_SSR(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 nd = tex2Dlod(sND, float4(uv, 0, 0));
	float z = nd.w;
	if (z >= DepthFar) return 0.0;
	float3 N = nd.xyz;
	float up = saturate((-N.y - 0.55) / 0.35); // view-space y points down
	float3 alb = tex2Dlod(sHalfCol, float4(uv, 0, 0)).rgb;
	float grass = saturate((alb.g - max(alb.r, alb.b)) / max(alb.g, 1e-3) * 4.0);
	float mask = up * (1.0 - grass * SSRGrassReject);
	if (mask < 0.01) return 0.0;

	float3 P = ViewPos(uv, z);
	float3 Vd = normalize(P);
	float3 R = reflect(Vd, N);
	float facing = saturate(R.z * 3.0 + 0.3);
	if (facing <= 0.0) return 0.0;

	float t = z * 0.01 * (1.0 + IGN(vpos.xy));
	float3 hitC = 0.0;
	float conf = 0.0;
	float3 Q = P;
	[loop] for (int i = 0; i < SSRSteps; i++)
	{
		float3 prevQ = Q;
		Q = P + R * t;
		if (Q.z <= 0.0) break;
		float2 q = ProjUV(Q);
		if (any(q < 0.0) || any(q > 1.0)) break;
		float sz = tex2Dlod(sND, float4(q, 0, 0)).w;
		float dz = Q.z - sz;
		if (dz > 0.0 && dz < max(t * 0.35, z * 0.02))
		{
			// Binary refinement between the last miss and this hit.
			float3 a = prevQ, b = Q;
			[unroll] for (int r = 0; r < 4; r++)
			{
				float3 mid = 0.5 * (a + b);
				float2 mq = ProjUV(mid);
				if (mid.z - tex2Dlod(sND, float4(mq, 0, 0)).w > 0.0) b = mid; else a = mid;
			}
			q = ProjUV(b);
			float2 edge = saturate(min(q, 1.0 - q) * 8.0);
			conf = edge.x * edge.y * (1.0 - (float)i / SSRSteps) * facing;
			hitC = tex2Dlod(sHalfCol, float4(q, 0, 0)).rgb;
			break;
		}
		t *= 1.3;
	}
	return float4(hitC * conf * mask, conf * mask); // premultiplied so bilinear upsampling of misses doesn't darken
}

float4 PS_SSRComposite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c = tex2D(sBackPt, uv);
	float d = RawDepth(uv);
	if (IsSky(d) || IsUiDepth(d)) return c;
	float zf = LinDepth(d) * DepthFar;
	float4 r = UpsampleEffect(sSSR, uv, zf);
	if (Bad4(r) || r.a <= 0.001) return c;
	float3 N = tex2Dlod(sNDLin, float4(uv, 0, 0)).xyz;
	float3 V = -normalize(ViewPos(uv, zf));
	float f0 = 0.02 + 0.25 * SSRWetness;
	float fres = f0 + (1.0 - f0) * pow(1.0 - saturate(dot(N, V)), 5.0);
	float3 lin = ToLin(c.rgb);
	// Specular adds on top of the (slightly darkened, "wet") surface instead of replacing it.
	float k = saturate(fres * SSRStrength * saturate(r.a * 2.0)) * 0.6;
	lin = lin * (1.0 - k * 0.35) + r.rgb / r.a * k;
	return float4(ToGam(lin), c.a);
}

// ----------------------------------------------------------------------------
// NS_LightShafts
// ----------------------------------------------------------------------------

float4 PS_ShaftMask(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float d = RawDepth(uv);
	// Open sky emits fully; bright distant scenery (sunlit haze, far walls) emits at half strength.
	float src = IsSky(d) ? 1.0 : (IsUiDepth(d) ? 0.0 : smoothstep(0.75, 0.95, LinDepth(d)) * 0.5);
	if (src <= 0.0) return 0.0;
	float3 c = tex2D(sBack, uv).rgb;
	float b = saturate((Luma(c) - ShaftThreshold) / (1.0 - ShaftThreshold));
	return float4(ToLin(c) * b * b * src, 1.0);
}

float4 RadialBlur(sampler src, float2 uv, float2 vpos, float len)
{
	float2 L = tex2Dfetch(sLight, int2(0, 0)).xy;
	float2 delta = (uv - L) * len / ShaftSamples;
	float2 p = uv - delta * IGN(vpos);
	float4 sum = 0.0;
	float decay = 1.0, wsum = 0.0;
	[loop] for (int i = 0; i < ShaftSamples; i++)
	{
		sum += tex2Dlod(src, float4(p, 0, 0)) * decay;
		wsum += decay;
		decay *= 0.96;
		p -= delta;
	}
	return sum / wsum;
}
float4 PS_ShaftBlur1(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return RadialBlur(sShaft0, uv, vpos.xy, ShaftLength); }
float4 PS_ShaftBlur2(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return RadialBlur(sShaft1, uv, vpos.yx, ShaftLength * 0.35); }

float4 PS_ShaftComposite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c = tex2D(sBackPt, uv);
	float4 s = State();
	float3 sh = tex2D(sShaft0, uv).rgb * ShaftStrength * s.z * s.x * ShaftTint;
	float3 lin = ToLin(c.rgb);
	lin = 1.0 - (1.0 - lin) * (1.0 - saturate(sh)); // screen blend: never clips to flat white
	lin = ToGam(lin);
	return float4(Bad3(lin) ? c.rgb : lin, c.a);
}

// ----------------------------------------------------------------------------
// NS_Bloom
// ----------------------------------------------------------------------------

float3 Down13(sampler s, float2 uv, float2 px)
{
	float3 a = tex2Dlod(s, float4(uv + px * float2(-2, -2), 0, 0)).rgb;
	float3 b = tex2Dlod(s, float4(uv + px * float2(0, -2), 0, 0)).rgb;
	float3 c = tex2Dlod(s, float4(uv + px * float2(2, -2), 0, 0)).rgb;
	float3 d = tex2Dlod(s, float4(uv + px * float2(-2, 0), 0, 0)).rgb;
	float3 e = tex2Dlod(s, float4(uv, 0, 0)).rgb;
	float3 f = tex2Dlod(s, float4(uv + px * float2(2, 0), 0, 0)).rgb;
	float3 g = tex2Dlod(s, float4(uv + px * float2(-2, 2), 0, 0)).rgb;
	float3 h = tex2Dlod(s, float4(uv + px * float2(0, 2), 0, 0)).rgb;
	float3 i = tex2Dlod(s, float4(uv + px * float2(2, 2), 0, 0)).rgb;
	float3 j = tex2Dlod(s, float4(uv + px * float2(-1, -1), 0, 0)).rgb;
	float3 k = tex2Dlod(s, float4(uv + px * float2(1, -1), 0, 0)).rgb;
	float3 l = tex2Dlod(s, float4(uv + px * float2(-1, 1), 0, 0)).rgb;
	float3 m = tex2Dlod(s, float4(uv + px * float2(1, 1), 0, 0)).rgb;
	return e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
}

float3 Tent(sampler s, float2 uv, float2 px)
{
	float3 r = tex2Dlod(s, float4(uv, 0, 0)).rgb * 4.0;
	r += (tex2Dlod(s, float4(uv + float2(px.x, 0), 0, 0)).rgb + tex2Dlod(s, float4(uv - float2(px.x, 0), 0, 0)).rgb
		+ tex2Dlod(s, float4(uv + float2(0, px.y), 0, 0)).rgb + tex2Dlod(s, float4(uv - float2(0, px.y), 0, 0)).rgb) * 2.0;
	r += tex2Dlod(s, float4(uv + px, 0, 0)).rgb + tex2Dlod(s, float4(uv - px, 0, 0)).rgb
		+ tex2Dlod(s, float4(uv + float2(px.x, -px.y), 0, 0)).rgb + tex2Dlod(s, float4(uv + float2(-px.x, px.y), 0, 0)).rgb;
	return r / 16.0;
}

float4 PS_BloomPrefilter(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float3 c = ToLin(Down13(sBack, uv, PIX));
	float l = Luma(ToGam(c));
	float knee = BloomSoftness;
	float soft = clamp(l - BloomThreshold + knee, 0.0, 2.0 * knee);
	soft = soft * soft / (4.0 * knee + 1e-4);
	float w = max(soft, l - BloomThreshold) / max(l, 1e-4);
	// Keep the HUD from glowing: no bloom source inside protected HUD areas or on depth-0 UI pixels.
	// Emissive FX (chakra, fire): bright AND strongly coloured. Clothing/grass are rarely both, so they stay calm.
	float3 g = ToGam(c);
	float mx = max(g.r, max(g.g, g.b)), sat = mx - min(g.r, min(g.g, g.b));
	float grass = saturate((g.g - max(g.r, g.b)) * 6.0) * step(g.b, g.r);
	// Additive jutsu FX render near-clipped; bright clothing (e.g. Shikamaru's teal vest) stays below this.
	float fx = smoothstep(0.92, 0.99, mx) * smoothstep(0.45, 0.7, sat / max(mx, 1e-3)) * smoothstep(0.55, 0.7, l) * (1.0 - grass);
	float hud = max(HudRectMask(uv), IsUiDepth(RawDepth(uv)) ? 1.0 : 0.0);
	float yellow = YellowMask(g);
	return float4(c * (saturate(w) + fx * FXGlow) * (1.0 - yellow) * (1.0 - hud), 1.0);
}
float4 PS_BloomDown2(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Down13(sB1, uv, 2.0 * PIX), 1); }
float4 PS_BloomDown3(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Down13(sB2, uv, 4.0 * PIX), 1); }
float4 PS_BloomDown4(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Down13(sB3, uv, 8.0 * PIX), 1); }
float4 PS_BloomDown5(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Down13(sB4, uv, 16.0 * PIX), 1); }
float4 PS_BloomDown6(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Down13(sB5, uv, 32.0 * PIX), 1); }
// Upsample chain is accumulated additively into the down-sampled textures (blend ONE, ONE).
float4 PS_BloomUp5(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Tent(sB6, uv, 64.0 * PIX) * BloomRadius, 1); }
float4 PS_BloomUp4(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Tent(sB5, uv, 32.0 * PIX) * BloomRadius, 1); }
float4 PS_BloomUp3(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Tent(sB4, uv, 16.0 * PIX) * BloomRadius, 1); }
float4 PS_BloomUp2(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Tent(sB3, uv, 8.0 * PIX), 1); }
float4 PS_BloomUp1(float4 v : SV_Position, float2 uv : TEXCOORD) : SV_Target { return float4(Tent(sB2, uv, 4.0 * PIX), 1); }

float3 BloomResult(float2 uv)
{
	// Normalise by the summed level weights so Wide glow changes shape, not brightness.
	float norm = 3.0 + 3.0 * BloomRadius;
	return Tent(sB1, uv, 2.0 * PIX) / norm * BloomTint;
}

float3 ChromaTap(float2 uv, float2 dir)
{
	// Chromatic fringe: red/blue sampled slightly apart along the flare axis.
	// Only hotspots (jutsu cores, sun) feed the flare: subtract a high threshold from the accumulated bloom level.
	float3 c = float3(tex2Dlod(sB3, float4(uv + dir * 0.006, 0, 0)).r, tex2Dlod(sB3, float4(uv, 0, 0)).g, tex2Dlod(sB3, float4(uv - dir * 0.006, 0, 0)).b);
	return max(c - 1.0, 0.0);
}

float4 PS_Flare(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float2 fuv = 1.0 - uv; // ghosts mirror bright sources through the screen centre
	float2 gvec = (0.5 - fuv) * 0.25;
	float2 dir = normalize(gvec + 1e-5);
	float3 r = 0.0;
	[loop] for (int i = 0; i < 5; i++)
	{
		float2 o = fuv + gvec * i;
		float inside = all(o >= 0.0) && all(o <= 1.0) ? 1.0 : 0.0;
		float w = pow(saturate(1.0 - length(0.5 - o) / 0.7071), 8.0) * inside;
		float3 tint = i == 2 ? float3(1.0, 0.6, 0.3) : (i == 4 ? float3(0.4, 0.7, 1.0) : float3(1.0, 1.0, 1.0));
		r += ChromaTap(saturate(o), dir) * w * tint;
	}
	r *= FlareIntensity;
	float2 h = fuv + dir * 0.3;
	float hw = pow(saturate(1.0 - length(0.5 - frac(h)) / 0.7071), 5.0);
	r += ChromaTap(frac(h), dir) * hw * FlareHalo;

	// Anamorphic streak: wide horizontal smear of hotspots only (computed here at quarter res).
	float3 st = 0.0;
	[loop] for (int j = -6; j <= 6; j++)
		st += max(tex2Dlod(sB4, float4(uv + float2(j * 0.008, 0), 0, 0)).rgb - 1.0, 0.0) * (1.0 - abs((float)j) / 7.0);
	r += st / 7.0 * StreakIntensity * StreakTint;
	return float4(r * 0.5 * State().x, 1.0);
}

float4 PS_BloomComposite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c = tex2D(sBackPt, uv);
	float3 lin = ToLin(c.rgb);
	float3 b = BloomResult(uv) * BloomIntensity * 4.0 * State().x;
	b += tex2D(sFlare, uv).rgb;
	// Glow spills into darker surroundings; already-bright surfaces barely brighten, so large pale areas don't blow out.
	float3 room = 1.0 - saturate(lin);
	lin = lin + b * room * room;
	lin = ToGam(lin);
	return float4(Bad3(lin) ? c.rgb : lin, c.a);
}

// ----------------------------------------------------------------------------
// NS_Sharpen - contrast-adaptive sharpening with min/max clamp (no halos on cel outlines)
// ----------------------------------------------------------------------------

float4 PS_Sharpen(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 c4 = tex2D(sBackPt, uv);
	float3 c = c4.rgb;
	float3 n = tex2Dlod(sBackPt, float4(uv + float2(0, -PIX.y), 0, 0)).rgb;
	float3 s = tex2Dlod(sBackPt, float4(uv + float2(0, PIX.y), 0, 0)).rgb;
	float3 e = tex2Dlod(sBackPt, float4(uv + float2(PIX.x, 0), 0, 0)).rgb;
	float3 w = tex2Dlod(sBackPt, float4(uv + float2(-PIX.x, 0), 0, 0)).rgb;
	float3 mn = min(c, min(min(n, s), min(e, w)));
	float3 mx = max(c, max(max(n, s), max(e, w)));
	float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
	float d = RawDepth(uv);
	float k = SharpStrength * (1.0 - SharpFarFade * saturate(LinDepth(d) * 3.0));
	if (IsSky(d)) k *= 0.3;
	float3 wt = -amp * lerp(0.1, 0.25, k) * saturate(k * 2.0);
	float3 r = clamp((c + (n + s + e + w) * wt) / (1.0 + 4.0 * wt), mn, mx);

	// Wide unsharp mask on luma (1.5 px ring), overshoot limited to +-0.06.
	float2 o = PIX * 1.5;
	float blur = (Luma(tex2Dlod(sBack, float4(uv + float2(o.x, o.y), 0, 0)).rgb) + Luma(tex2Dlod(sBack, float4(uv + float2(-o.x, o.y), 0, 0)).rgb)
		+ Luma(tex2Dlod(sBack, float4(uv + float2(o.x, -o.y), 0, 0)).rgb) + Luma(tex2Dlod(sBack, float4(uv - o, 0, 0)).rgb)) * 0.25;
	float detail = clamp((Luma(c) - blur) * SharpDetail * (k / max(SharpStrength, 1e-3)), -0.1, 0.1);
	return float4(saturate(r + detail), c4.a);
}

// ----------------------------------------------------------------------------
// NS_Finish - fog, grade, vignette, HUD/menu restore, debug
// ----------------------------------------------------------------------------

float3 ApplyFog(float3 lin, float2 uv, float d)
{
	if (!FogEnable || IsUiDepth(d)) return lin;
	float4 sky = tex2Dfetch(sSky, int2(0, 0));
	float3 fc = lerp(ToLin(FogColor), sky.rgb, FogAutoColor * saturate(sky.w * 20.0));
	float2 L = tex2Dfetch(sLight, int2(0, 0)).xy;
	float sun = State().z * FogSunGlow * saturate(1.0 - length((uv - L) * float2(ASPECT, 1.0)) * 1.2);
	fc *= 1.0 + sun * 0.6;
	float ld = LinDepth(d);
	float x = FogDensity * max(ld - FogStart, 0.0) * 4.0;
	float f = IsSky(d) ? 0.0 : (1.0 - exp(-x * x)) * FogMax; // exp^2: clear foreground, haze builds in the distance
	return lerp(lin, fc, f);
}

float3 Grade(float3 lin, float2 uv, float adaptMul)
{
	if (!GradeEnable) return lin;
	float4 ad = tex2Dfetch(sAdapt, int2(0, 0));
	// Emissive jutsu/chakra light (bright + strongly coloured) is exempt from darkening so it pops in moody scenes.
	float3 g0 = ToGam(saturate(lin));
	float gmx = max(g0.r, max(g0.g, g0.b));
	float emissive = smoothstep(0.92, 0.99, gmx) * smoothstep(0.45, 0.7, (gmx - min(g0.r, min(g0.g, g0.b))) / max(gmx, 1e-3)) * (1.0 - YellowMask(g0));
	lin *= exp2((Exposure + ad.x * AdaptExposure * adaptMul) * (1.0 - emissive));
	lin *= float3(1.0 + Temperature * 0.08, 1.0, 1.0 - Temperature * 0.08);

	// Filmic contrast around mid-grey in log space, applied on luminance to keep hue.
	float l = Luma(lin);
	float lc = 0.18 * pow(max(l, 1e-5) / 0.18, Contrast);
	// Smooth highlight shoulder: anything above the knee rolls off toward 1 instead of clipping.
	float knee = lerp(1.0, 0.6, HighlightRolloff);
	if (lc > knee) lc = knee + (1.0 - knee) * (1.0 - exp(-(lc - knee) / max(1.0 - knee, 1e-3)));
	// ACES fit (Narkowicz) on luminance only, input scaled by 0.571 and divided by its value at 1.5,
	// so mid-grey 0.18 -> 0.17, 1.5 -> white, and the toe deepens shadows (0.05 -> 0.024).
	float xa = lc * 0.571;
	float aces = (xa * (2.51 * xa + 0.03)) / (xa * (2.43 * xa + 0.59) + 0.14) / 0.769;
	lc = lerp(lc, aces, FilmicStrength);
	lin *= lc / max(l, 1e-5);
	lin = max(lin, 0.0);

	// Split toning by luminance.
	l = Luma(lin);
	float hw = smoothstep(0.1, 0.8, l);
	lin *= lerp(ShadowTint, HighlightTint, hw);

	// Saturation + vibrance with skin-tone protection (orange hues at moderate saturation).
	float3 g = ToGam(saturate(lin));
	float mx = max(g.r, max(g.g, g.b)), mn = min(g.r, min(g.g, g.b));
	float sat = mx - mn;
	float skin = (g.r >= g.g && g.g >= g.b) ? saturate(1.0 - abs((g.g - g.b) / max(sat, 1e-4) - 0.45) * 3.0) * saturate(1.0 - abs(sat - 0.35) * 3.0) : 0.0;
	// Near-neutral colours (whites, greys) are left alone so whites stay clean like inked colour art.
	// Teal/cyan clothing (e.g. Shikamaru's jacket) drifts toward electric blue when boosted: protect hues ~150-200 deg.
	float hue = 0.0;
	if (sat > 1e-4)
	{
		if (mx == g.r) hue = frac(((g.g - g.b) / sat) / 6.0);
		else if (mx == g.g) hue = ((g.b - g.r) / sat + 2.0) / 6.0;
		else hue = ((g.r - g.g) / sat + 4.0) / 6.0;
	}
	float teal = saturate(1.0 - abs(hue - 0.48) * 9.0);
	float vib = (Vibrance + ad.y * AdaptVibrance * 0.8 * adaptMul) * (1.0 - sat) * smoothstep(0.04, 0.2, sat) * (1.0 - skin * 0.8) * (1.0 - teal * 0.7);
	float satMul = lerp(1.0, lerp(Saturation, 1.0, teal * 0.7), smoothstep(0.02, 0.12, sat));
	l = Luma(lin);
	lin = lerp(l.xxx, lin, max(satMul * (1.0 + vib), 0.0));

	// Shadow lift (detail), then vignette.
	lin = lin + ShadowLift * (1.0 - saturate(lin)) * (1.0 - saturate(lin));
	float2 v = (uv - 0.5) * float2(ASPECT, 1.0) / ASPECT * 1.4;
	lin *= 1.0 - Vignette * 0.35 * smoothstep(0.3, 1.0, dot(v, v));
	return lin;
}

float4 PS_Finish(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float3 proc = tex2D(sBackPt, uv).rgb;
	float3 orig = tex2D(sOrig, uv).rgb;
	float d = RawDepth(uv);
	float4 st = State();

	// Inside HUD boxes the scene keeps only per-pixel effects (fog + grade), so no spatial effect touches the HUD.
	if (!IsSky(d) && !IsUiDepth(d))
	{
		float z = LinDepth(d);
		float distFade = 1.0 - smoothstep(0.55, 0.9, z);

		// Rim light: near side of a silhouette picks up the (bright) background just behind it.
		if (RimStrength > 0.0)
		{
			float3 rim = 0.0;
			[unroll] for (int r = 0; r < 4; r++)
			{
				float2 dir = r == 0 ? float2(1, 0) : (r == 1 ? float2(-1, 0) : (r == 2 ? float2(0, 1) : float2(0, -1)));
				float2 suv = uv + dir * PIX * RimWidth;
				float sd = RawDepth(suv);
				float behind = IsSky(sd) ? 1.0 : smoothstep(0.1, 0.4, (LinDepth(sd) - z) / z);
				float3 bg = tex2Dlod(sHalfCol, float4(suv, 0, 0)).rgb;
				rim = max(rim, bg * behind * smoothstep(0.25, 0.7, Luma(ToGam(bg))));
			}
			float3 pl = ToLin(proc);
			pl = 1.0 - (1.0 - pl) * (1.0 - saturate(rim * RimTint * RimStrength * 0.6));
			proc = ToGam(pl);
		}

		// Cel shading: soft-quantise luminance into bands, keeping hue and texture ratios.
		if (CelStrength > 0.0)
		{
			float3 pl = ToLin(proc);
			float l = Luma(pl);
			float g = sqrt(l) * CelBands; // bands spaced perceptually
			float band = (floor(g) + smoothstep(0.2, 0.8, frac(g))) / CelBands;
			pl *= lerp(1.0, band * band / max(l, 1e-4), CelStrength * distFade);
			proc = ToGam(pl);
		}

		// Ink lines: depth silhouettes + normal creases, sampled InkWidth pixels out.
		float2 o = PIX * InkWidth;
		float zn = LinDepth(RawDepth(uv + float2(0, -o.y))), zs = LinDepth(RawDepth(uv + float2(0, o.y)));
		float ze = LinDepth(RawDepth(uv + float2(o.x, 0))), zw = LinDepth(RawDepth(uv + float2(-o.x, 0)));
		// Only the far side of an edge darkens (neighbour nearer than us), so lines stay thin and sit outside silhouettes.
		float sil = smoothstep(0.03, 0.12, max(max(z - zn, z - zs), max(z - ze, z - zw)) / z);
		float3 nc = tex2Dlod(sNDLin, float4(uv, 0, 0)).xyz;
		float crease = 0.0;
		[unroll] for (int i = 0; i < 4; i++)
		{
			float2 dir = i == 0 ? float2(o.x, 0) : (i == 1 ? float2(-o.x, 0) : (i == 2 ? float2(0, o.y) : float2(0, -o.y)));
			float4 s4 = tex2Dlod(sNDLin, float4(uv + dir * 1.5, 0, 0));
			if (s4.w < DepthFar) crease = max(crease, 1.0 - dot(nc, s4.xyz));
		}
		crease = smoothstep(0.35, 0.75, crease) * InkCrease;
		float3 pc = saturate(proc);
		float foliage = saturate((pc.g - max(pc.r, pc.b)) / max(pc.g, 1e-3) * 5.0);
		proc *= 1.0 - InkStrength * saturate(max(sil, crease)) * distFade * lerp(1.0, InkFoliage, foliage);
	}

	float hud = HudRectMask(uv);
	float3 c = lerp(proc, orig, hud);
	float3 lin = Grade(ApplyFog(ToLin(c), uv, d), uv, 1.0 - hud);
	float3 outc = ToGam(lin) + (IGN(vpos.xy) - 0.5) / 255.0;
	if (Bad3(outc)) outc = orig;

	// Exact UI pixels and menus/videos stay original.
	float keep = IsUiDepth(d) && HudProtect ? 1.0 : 0.0;
	if (MenuBypass) keep = max(keep, 1.0 - st.x);
	outc = lerp(outc, orig, keep);

	if (DebugView == 1) return float4(LinDepth(d).xxx, 1);
	if (DebugView == 2) return float4(tex2D(sNDLin, uv).xyz * float3(0.5, -0.5, -0.5) + 0.5, 1);
	if (DebugView == 3) { float4 g = UpsampleEffect(sGI1, uv, LinDepth(d) * DepthFar); return float4(ToGam(g.aaa * (1.0 + g.rgb * 4.0)), 1); }
	if (DebugView == 4) { float4 r = tex2D(sSSR, uv); return float4(ToGam(r.rgb) + float3(0, 0, r.a * 0.3), 1); }
	if (DebugView == 5) return float4(ToGam(tex2D(sShaft0, uv).rgb * 4.0), 1);
	if (DebugView == 6) return float4(ToGam(BloomResult(uv) * 4.0), 1);
	if (DebugView == 7) return float4(lerp(outc, float3(1, 0, 1), max(hud, keep) * 0.6), 1);
	if (DebugView == 8)
	{
		if (uv.y < 0.05) return float4(uv.x < 0.33 ? st.xxx : (uv.x < 0.66 ? float3(st.y, 0, 0) : float3(0, st.z, 0)), 1);
		float2 L = tex2Dfetch(sLight, int2(0, 0)).xy;
		if (length((uv - L) * float2(ASPECT, 1)) < 0.02) return float4(1, 1, 0, 1);
		return float4(outc, 1);
	}
	if (DebugView == 9) return float4(uv.x < 0.5 ? orig : outc, 1);
	if (DebugView == 10)
	{
		// Red = depth silhouettes over the untouched frame; they must hug the visible outlines.
		float z = LinDepth(d);
		float e = abs(LinDepth(RawDepth(uv + float2(PIX.x, 0))) - z) + abs(LinDepth(RawDepth(uv + float2(0, PIX.y))) - z);
		return float4(e / max(z, 1e-4) > 0.05 ? float3(1, 0, 0) : orig, 1);
	}
	return float4(outc, 1);
}

// ----------------------------------------------------------------------------
// Techniques
// ----------------------------------------------------------------------------

technique NS_Begin < ui_tooltip = "REQUIRED. Keep at the TOP of the list. Prepares depth/normals, detects HUD and menus."; >
{
	pass Prep { VertexShader = PostProcessVS; PixelShader = PS_Prep; RenderTarget0 = texNSNormDepth; RenderTarget1 = texNSHalfCol; }
	pass Save { VertexShader = PostProcessVS; PixelShader = PS_SaveOrig; RenderTarget = texNSOrig; }
	pass Small { VertexShader = PostProcessVS; PixelShader = PS_Small; RenderTarget0 = texNSSmall0; RenderTarget1 = texNSSmall1; RenderTarget2 = texNSSmall2; }
	pass Resolve { VertexShader = PostProcessVS; PixelShader = PS_Resolve; RenderTarget0 = texNSState; RenderTarget1 = texNSLight; RenderTarget2 = texNSSky; RenderTarget3 = texNSAdapt; }
	pass Copy { VertexShader = PostProcessVS; PixelShader = PS_CopyPrev; RenderTarget0 = texNSStatePrev; RenderTarget1 = texNSLightPrev; RenderTarget2 = texNSSkyPrev; RenderTarget3 = texNSAdaptPrev; }
}

technique NS_AntiAliasing < ui_tooltip = "Edge anti-aliasing. Turn the game's own FXAA off when using this."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_AA; }
}

technique NS_RTGI < ui_tooltip = "Simulated ray-traced lighting: ambient occlusion + one-bounce colour bleeding (screen-space)."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_GI; RenderTarget = texNSGI0; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_GIBlur; RenderTarget = texNSGI1; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_GIComposite; }
}

technique NS_Reflections < ui_tooltip = "Screen-space reflections on floors and other upward-facing surfaces."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_SSR; RenderTarget = texNSSSR; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_SSRComposite; }
}

technique NS_LightShafts < ui_tooltip = "God rays from bright sky. Fades out automatically when no bright sky is visible."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_ShaftMask; RenderTarget = texNSShaft0; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_ShaftBlur1; RenderTarget = texNSShaft1; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_ShaftBlur2; RenderTarget = texNSShaft0; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_ShaftComposite; }
}

technique NS_Bloom < ui_tooltip = "Cinematic bloom, jutsu glow, lens flare and anamorphic streaks. HUD areas are excluded from the glow source."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomPrefilter; RenderTarget = texNSB1; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomDown2; RenderTarget = texNSB2; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomDown3; RenderTarget = texNSB3; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomDown4; RenderTarget = texNSB4; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomDown5; RenderTarget = texNSB5; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomDown6; RenderTarget = texNSB6; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomUp5; RenderTarget = texNSB5; BlendEnable = true; SrcBlend = ONE; DestBlend = ONE; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomUp4; RenderTarget = texNSB4; BlendEnable = true; SrcBlend = ONE; DestBlend = ONE; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomUp3; RenderTarget = texNSB3; BlendEnable = true; SrcBlend = ONE; DestBlend = ONE; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomUp2; RenderTarget = texNSB2; BlendEnable = true; SrcBlend = ONE; DestBlend = ONE; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomUp1; RenderTarget = texNSB1; BlendEnable = true; SrcBlend = ONE; DestBlend = ONE; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_Flare; RenderTarget = texNSFlare; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomComposite; }
}

technique NS_Sharpen < ui_tooltip = "Contrast-adaptive sharpening that never overshoots the black cel-shading outlines."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_Sharpen; }
}

float PS_StoreDepth(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target { return tex2Dlod(sDepth, float4(uv, 0, 0)).x; }

technique NS_Finish < ui_tooltip = "REQUIRED. Keep at the BOTTOM of the list. Fog, colour grading, HUD and menu protection."; >
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_Finish; }
	// Runs last: next frame reads this as its (delayed) depth.
	pass { VertexShader = PostProcessVS; PixelShader = PS_StoreDepth; RenderTarget = texNSDepthHist; }
}
