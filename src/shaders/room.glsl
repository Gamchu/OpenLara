R"====(
#define MAX_LIGHTS			4
#define MAX_CONTACTS		15
#define WATER_FOG_DIST		(1.0 / (6.0 * 1024.0))
#define WATER_COLOR_DIST	(1.0 / (2.0 * 1024.0))
#define UNDERWATER_COLOR	vec3(0.6, 0.9, 0.9)

#define SHADOW_NORMAL_BIAS	16.0
#define SHADOW_CONST_BIAS	0.05

#ifdef OPT_CAUSTICS
	uniform vec4 uRoomSize; // xy - minXZ, zw - maxXZ
#endif

#ifdef OPT_SHADOW
	#define SHADOW_TEXEL	vec3(1.0 / SHADOW_SIZE, 1.0 / SHADOW_SIZE, 0.0)
	uniform mat4 uLightProj;

	#ifdef OPT_VLIGHTPROJ
		varying vec4 vLightProj;
	#endif
#endif

uniform mat4 uViewProj;
uniform vec4 uViewPos;

uniform vec4 uParam;	// x - time, y - water height, z - clip plane sign, w - clip plane height
uniform vec4 uLightPos[MAX_LIGHTS];
uniform vec4 uLightColor[MAX_LIGHTS]; // xyz - color, w - radius * intensity
uniform vec4 uMaterial;	// x - diffuse, y - ambient, z - specular, w - alpha
uniform vec4 uFogParams;

varying vec4 vViewVec;	// xyz - dir * dist, w - coord.y * clipPlaneSign
varying vec4 vDiffuse;

varying vec3 vCoord;
varying vec4 vNormal;	// xyz - normal dir, w - fog factor

#ifdef OPT_SHADOW
	varying vec3 vAmbient;
	varying vec3 vLightMap;
#endif

varying vec4 vLight;	// lights intensity (MAX_LIGHTS == 4)

varying vec4 vTexCoord; // xy - atlas coords, zw - trapezoidal correction

#ifdef OPT_VLIGHTVEC
	varying vec3 vLightVec;
#endif

#ifdef OPT_SHADOW
	vec4 calcLightProj(vec3 coord, vec3 lightVec, vec3 normal) {
		float factor = clamp(1.0 - dot(normalize(lightVec), normal), 0.0, 1.0);
		factor *= SHADOW_NORMAL_BIAS;
		return uLightProj * vec4(coord + normal * factor, 1.0);
	}
#endif

#ifdef VERTEX

	uniform vec4 uBasis[2];

	attribute vec4 aCoord;
	attribute vec4 aTexCoord;
	attribute vec4 aNormal;

	attribute vec4 aColor;
	attribute vec4 aLight;

	vec3 mulQuat(vec4 q, vec3 v) {
		return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + v * q.w);
	}

	vec3 mulBasis(vec4 rot, vec3 pos, vec3 v) {
		return mulQuat(rot, v) + pos;
	}

	vec4 _transform() {
		vec4 rBasisRot = uBasis[0];
		vec4 rBasisPos = uBasis[1];

		vec3 coord = mulBasis(rBasisRot, rBasisPos.xyz, aCoord.xyz);

		vViewVec = vec4((uViewPos.xyz - coord) * uFogParams.w, 0.0);

		vNormal.xyz = normalize(mulQuat(rBasisRot, aNormal.xyz));

		float fog;
		#if defined(UNDERWATER) && !defined(OPT_UNDERWATER_FOG)
			float d = length(uViewPos.xyz - coord);
			if (uViewPos.y < uParam.y) {
				d *= (coord.y - uParam.y) / (coord.y - uViewPos.y);
			}
			fog = d * WATER_FOG_DIST;
			fog *= step(uParam.y, coord.y);
		#else
			fog = length(vViewVec.xyz);
		#endif
		vNormal.w = clamp(1.0 / exp(fog), 0.0, 1.0);

		vCoord = coord;

		return vec4(coord, rBasisPos.w);
	}

	void _diffuse() {
		vDiffuse = vec4(aColor.xyz * uMaterial.x, 1.0);
		vDiffuse.xyz *= 2.0;
		vDiffuse *= uMaterial.w;
	}

	void _lighting(vec3 coord) {
		vec3 lv0 = (uLightPos[0].xyz - coord) * uLightColor[0].w;
		vec3 lv1 = (uLightPos[1].xyz - coord) * uLightColor[1].w;
		vec3 lv2 = (uLightPos[2].xyz - coord) * uLightColor[2].w;
		vec3 lv3 = (uLightPos[3].xyz - coord) * uLightColor[3].w;

		#ifdef OPT_VLIGHTVEC
			vLightVec = lv0;
		#endif

		vec4 lum, att;
		lum.x = 1.0;
		att.x = 0.0;


		lum.y = dot(vNormal.xyz, normalize(lv1)); att.y = dot(lv1, lv1);
		lum.z = dot(vNormal.xyz, normalize(lv2)); att.z = dot(lv2, lv2);
		lum.w = dot(vNormal.xyz, normalize(lv3)); att.w = dot(lv3, lv3);
		vec4 light = max(vec4(0.0), lum) * max(vec4(0.0), vec4(1.0) - att);

		#if defined(UNDERWATER) && defined(VERT_CAUSTICS)
			light.x *= 0.5 + abs(sin(dot(coord.xyz, vec3(1.0 / 1024.0)) + uParam.x)) * 0.75;
		#endif

		vec3 ambient = min(uMaterial.yyy, aLight.xyz);

		#ifdef OPT_SHADOW
			vAmbient   = ambient;
			vLight     = light;
			vLightMap  = aLight.xyz * light.x;

			#ifdef OPT_VLIGHTPROJ
				vLightProj = calcLightProj(coord, lv0, vNormal.xyz);
			#endif

		#else
			vLight.xyz = uLightColor[1].xyz * light.y + uLightColor[2].xyz * light.z + uLightColor[3].xyz * light.w;
			vLight.w = 0.0;

			vLight.xyz += aLight.xyz * light.x;

		#endif
	}

	void _uv(vec3 coord) {
		vTexCoord = aTexCoord;
		#ifdef OPT_TRAPEZOID
			vTexCoord.xy *= vTexCoord.zw;
		#endif
	}

	void main() {
		vec4 coord = _transform();

		_diffuse();
		_lighting(coord.xyz);

		_uv(coord.xyz);

		gl_Position = uViewProj * coord;
	}

#else

	uniform sampler2D sDiffuse;

	float unpack(vec4 value) {
		return dot(value, vec4(1.0, 1.0/255.0, 1.0/65025.0, 1.0/16581375.0));
	}

	#ifdef OPT_SHADOW
		#ifdef SHADOW_SAMPLER
			uniform sampler2DShadow sShadow;
			#ifdef USE_GL_EXT_shadow_samplers
				#define SHADOW(V) (shadow2DEXT(sShadow, V))
			#else
				#define SHADOW(V) (shadow2D(sShadow, V).x)
			#endif
		#else
			uniform sampler2D sShadow;

			float SHADOW(vec2 p) {
				#ifdef SHADOW_DEPTH
					return texture2D(sShadow, p).x;
				#else
					return unpack(texture2D(sShadow, p));
				#endif
			}
		#endif

		float getShadow(vec3 lightVec, vec3 normal, vec4 lightProj) {
			vec3 p = lightProj.xyz / lightProj.w;
			p.z -= SHADOW_CONST_BIAS * SHADOW_TEXEL.x;

			float vis = min(lightProj.w, dot(normal, lightVec));
			if (min(vis, min(p.x, p.y)) < 0.0 || max(p.x, p.y) > 1.0) return 1.0;

			#ifdef SHADOW_SAMPLER
				float rShadow = SHADOW(p);
			#else
				#ifndef OPT_SHADOW_ONETAP
					vec4 samples = vec4(SHADOW(                  p.xy),
										SHADOW(SHADOW_TEXEL.xz + p.xy),
										SHADOW(SHADOW_TEXEL.zy + p.xy),
										SHADOW(SHADOW_TEXEL.xy + p.xy));

					samples = step(vec4(p.z), samples);

					vec2 f = fract(p.xy / SHADOW_TEXEL.xy);
					samples.xy = mix(samples.xz, samples.yw, f.x);
					float rShadow = mix(samples.x, samples.y, f.y);
				#else
					float rShadow = step(p.z, SHADOW(p.xy));
				#endif
			#endif

			float fade = clamp(dot(lightVec, lightVec), 0.0, 1.0);
			return rShadow + (1.0 - rShadow) * fade;
		}

		float getShadow(vec3 lightVec, vec3 normal) {
			#ifndef OPT_VLIGHTPROJ
				vec4 vLightProj = calcLightProj(vCoord, lightVec, normal);
			#endif
			return getShadow(lightVec, normal, vLightProj);
		}
	#endif

	#ifdef OPT_CAUSTICS
		uniform sampler2D sReflect;

		float calcCaustics(vec3 n) {
			vec2 cc = clamp((vCoord.xz - uRoomSize.xy) / uRoomSize.zw, vec2(0.0), vec2(1.0));
			vec2 border = vec2(256.0) / uRoomSize.zw;
			vec2 fade   = smoothstep(vec2(0.0), border, cc) * (1.0 - smoothstep(vec2(1.0) - border, vec2(1.0), cc));
			return texture2D(sReflect, cc).x * max(0.0, -n.y) * fade.x * fade.y;
		}
	#endif

	#ifdef OPT_CONTACT
		uniform vec4 uContacts[MAX_CONTACTS];
	
		float getContactAO(vec3 p, vec3 n) {
			float res = 1.0;
			for (int i = 0; i < MAX_CONTACTS; i++) {
				vec3  v = uContacts[i].xyz - p;
				float a = uContacts[i].w;
				float o = a * clamp(dot(n, v), 0.0, 1.0) / dot(v, v);
				res *= clamp(1.0 - o, 0.0, 1.0);
			}
			return res;
		}
	#endif

	float calcSpecular(vec3 normal, vec3 viewVec, vec3 lightVec, vec4 color, float intensity) {
		vec3 vv = normalize(viewVec);
		vec3 rv = reflect(-vv, normal);
		vec3 lv = normalize(lightVec);
		return pow(max(0.0, dot(rv, lv)), 8.0) * intensity;
	}

	void main() {
		vec2 uv = vTexCoord.xy;

		#ifdef OPT_TRAPEZOID
			uv /= vTexCoord.zw;
		#endif
		vec4 color = texture2D(sDiffuse, uv);

		#ifdef ALPHA_TEST
			if (color.w <= 0.5)
				discard;
		#endif

		color *= vDiffuse;

		#ifndef OPT_VLIGHTVEC
			vec3 vLightVec = (uLightPos[0].xyz - vCoord) * uLightColor[0].w;
		#endif

		vec3 normal = normalize(vNormal.xyz);

		#ifdef OPT_SHADOW
			vec3 light = uLightColor[1].xyz * vLight.y + uLightColor[2].xyz * vLight.z + uLightColor[3].xyz * vLight.w;

			float rShadow = getShadow(vLightVec, normal);

			light += mix(vAmbient, vLightMap, rShadow);
		#else
			vec3 light = vLight.xyz;
		#endif

		#ifdef UNDERWATER
			float uwSign = 1.0;

			#ifdef OPT_CAUSTICS
				light += calcCaustics(normal) * uwSign;
			#endif
		#endif

		#ifdef OPT_CONTACT
			light *= getContactAO(vCoord, normal) * 0.5 + 0.5;
		#endif

		color.xyz *= light;

		#ifdef UNDERWATER
			#ifdef OPT_UNDERWATER_FOG
				float dist;
				if (uViewPos.y < uParam.y)
					dist = abs((vCoord.y - uParam.y) / normalize(uViewPos.xyz - vCoord.xyz).y);
				else
					dist = length(uViewPos.xyz - vCoord.xyz);
				float fog = clamp(1.0 / exp(dist * WATER_FOG_DIST * uwSign), 0.0, 1.0);
				dist += vCoord.y - uParam.y;
				color.xyz *= mix(vec3(1.0), UNDERWATER_COLOR, clamp(dist * WATER_COLOR_DIST * uwSign, 0.0, 2.0));
				color.xyz = mix(UNDERWATER_COLOR * 0.2, color.xyz, fog);
			#else
				color.xyz = mix(color.xyz, color.xyz * UNDERWATER_COLOR, uwSign);
				color.xyz = mix(UNDERWATER_COLOR * 0.2, color.xyz, vNormal.w);
			#endif
		#else
			color.xyz = mix(uFogParams.xyz, color.xyz, vNormal.w);
		#endif

		fragColor = color;
	}

#endif
)===="