#pragma glsl3

varying vec3 v_position;

#ifdef VERTEX
uniform mat4 u_inv_view_proj;

vec4 position(mat4 _, vec4 vertex) {
	v_position = (u_inv_view_proj * vec4(vertex.x,vertex.y, 1.0, 1.0)).xyz;

	return vertex;
}
#endif

#ifdef PIXEL
uniform vec3 u_light_direction;

const vec3 luma = vec3(0.299, 0.587, 0.114);
const vec3 cameraPos = vec3(0.0, 0.0, 0.0);
const float luminance = 1.05;
const float turbidity = 8.0;
const float reileigh = 2.0;
const float mieCoefficient = 0.005;
const float mieDirectionalG = 0.8;

// constants for atmospheric scattering
const float e = 2.71828182845904523536028747135266249775724709369995957;
const float pi = 3.141592653589793238462643383279502884197169;

// refractive index of air
const float n = 1.0003;

// number of molecules per unit volume for air at 288.15K and 1013mb (sea level -45 celsius)
const float N = 2.545E25;

// depolatization factor for standard air
const float pn = 0.035;

// wavelength of used primaries, according to preetham
const vec3 lambda = vec3(680E-9, 550E-9, 450E-9);

// mie stuff
// K coefficient for the primaries
const vec3 K = vec3(0.686, 0.678, 0.666);
const float v = 4.0;

// optical length at zenith for molecules
const float rayleighZenithLength = 8.4E3;
const float mieZenithLength = 1.25E3;
const vec3 up = vec3(0.0, 0.0, 1.0);

const float EE = 1000.0;
const float sunAngularDiameterCos = 0.99996192306417*0.9995; // probably correct size

// earth shadow hack
const float steepness = 1.5;

vec4 rgbe8_encode(vec3 _rgb) {
	vec4 rgbe8;
	float maxComponent = max(max(_rgb.x, _rgb.y), _rgb.z);
	float exponent = ceil(log2(maxComponent) );
	rgbe8.xyz = _rgb / exp2(exponent);
	rgbe8.w = (exponent + 128.0) / 255.0;
	return rgbe8;
}

vec3 totalRayleigh(vec3 lambda) {
	return (8.0 * pow(pi, 3.0) * pow(pow(n, 2.0) - 1.0, 2.0) * (6.0 + 3.0 * pn)) / (3.0 * N * pow(lambda, vec3(4.0)) * (6.0 - 7.0 * pn));
}

// see http://blenderartists.org/forum/showthread.php?321110-Shaders-and-Skybox-madness
// A simplied version of the total Rayleigh scattering to works on browsers that use ANGLE
vec3 simplifiedRayleigh() {
	return 0.00054532832366 / vec3(94.0, 40.0, 18.0);
}

float rayleighPhase(float cosTheta) {	 
	return (3.0 / (16.0*pi)) * (1.0 + pow(cosTheta, 2.0));
}

vec3 totalMie(vec3 lambda, vec3 K, float T) {
	float c = (0.2 * T ) * 10E-18;
	return 0.434 * c * pi * pow((2.0 * pi) / lambda, vec3(v - 2.0)) * K;
}

float hgPhase(float cosTheta, float g) {
	return (1.0 / (4.0*pi)) * ((1.0 - pow(g, 2.0)) / pow(1.0 - 2.0*g*cosTheta + pow(g, 2.0), 1.5));
}

float sunIntensity(float zenithAngleCos) {
	// See https://github.com/mrdoob/three.js/issues/8382
	float cutoffAngle = pi/1.95;
	return EE * max(0.0, 1.0 - pow(e, -((cutoffAngle - acos(zenithAngleCos))/steepness)));
}

vec4 effect(vec4 _c, Image _i, vec2 _u, vec2 _s) {
	float sunfade = 1.0-clamp(1.0-exp((u_light_direction.y/450000.0)),0.0,1.0);
	float reileighCoefficient = reileigh - (1.0* (1.0-sunfade));
	vec3 sunDirection = normalize(u_light_direction);
	float sunE = sunIntensity(dot(sunDirection, up));

	// extinction (absorbtion + out scattering) 
	// rayleigh coefficients
	vec3 betaR = simplifiedRayleigh() * reileighCoefficient;

	// mie coefficients
	vec3 betaM = totalMie(lambda, K, turbidity) * mieCoefficient;

	// optical length
	// cutoff angle at 90 to avoid singularity in next formula.
	float zenithAngle = acos(max(0.0, dot(up, normalize(v_position.xyz - cameraPos))));
	float sR = rayleighZenithLength / (cos(zenithAngle) + 0.15 * pow(93.885 - ((zenithAngle * 180.0) / pi), -1.253));
	float sM = mieZenithLength / (cos(zenithAngle) + 0.15 * pow(93.885 - ((zenithAngle * 180.0) / pi), -1.253));

	// combined extinction factor	
	vec3 Fex = exp(-(betaR * sR + betaM * sM));

	// in scattering
	float cosTheta = dot(normalize(v_position.xyz - cameraPos), sunDirection);

	float rPhase = rayleighPhase(cosTheta*0.5+0.5);
	vec3 betaRTheta = betaR * rPhase;

	float mPhase = hgPhase(cosTheta, mieDirectionalG);
	vec3 betaMTheta = betaM * mPhase;

	vec3 Lin = pow(sunE * ((betaRTheta + betaMTheta) / (betaR + betaM)) * (1.0 - Fex),vec3(1.5));
	Lin *= mix(vec3(1.0),pow(sunE * ((betaRTheta + betaMTheta) / (betaR + betaM)) * Fex,vec3(1.0/2.0)),clamp(pow(1.0-dot(up, sunDirection),5.0),0.0,1.0));

	// night sky
	vec3 direction = normalize(v_position.xyz - cameraPos);
	float theta = acos(direction.y); // elevation --> y-axis, [-pi/2, pi/2]
	float phi = atan(direction.z/direction.x); // azimuth --> x-axis [-pi/2, pi/2]
	vec3 L0 = vec3(0.1) * Fex;

	// composition + solar disc
	float sundisk = smoothstep(sunAngularDiameterCos,sunAngularDiameterCos+0.001,cosTheta);
	L0 += (sunE * 19000.0 * Fex)*sundisk;

	vec3 texColor = (Lin+L0);   
	texColor *= 0.04;
	texColor += vec3(0.0,0.001,0.0025)*0.3;

	vec3 color = (log2(2.0/pow(luminance,4.0)))*texColor;

	vec3 retColor = pow(color,vec3(1.0/(1.2+(1.2*sunfade))));

	retColor = mix(retColor * 0.75, retColor, clamp(dot(direction, up) * 0.5 + 0.5, 0.0, 1.0));

	// vec4 out_color = vec4(retColor, 1.0);
	// out_color.a = dot(retColor, luma);
#ifndef GL_ES
	gl_FragDepth = 1.0;
#endif

	vec3 final = pow(retColor * 0.75, vec3(2.2));
	// final = sqrt(final);

#ifdef GL_ES
	return rgbe8_encode(final);
#else
	final *= final;
	return vec4(final, 1.0);
#endif
}
#endif
