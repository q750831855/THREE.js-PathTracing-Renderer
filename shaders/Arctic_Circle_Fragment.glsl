#version 300 es

precision highp float;
precision highp int;
precision highp sampler2D;

uniform vec3 uSunDirection;
uniform float uWaterLevel;

#include <pathtracing_uniforms_and_defines>

uniform sampler2D t_PerlinNoise;

#include <pathtracing_skymodel_defines>


//-----------------------------------------------------------------------

struct Ray { vec3 origin; vec3 direction; };
struct Quad { vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; int type; };
struct Box { vec3 minCorner; vec3 maxCorner; vec3 emission; vec3 color; int type; };
struct Intersection { vec3 normal; vec3 emission; vec3 color; vec2 uv; int type; };


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_plane_intersect>

#include <pathtracing_triangle_intersect>

#include <pathtracing_box_intersect>

#include <pathtracing_physical_sky_functions>

//----------------------------------------------------------------------------
float QuadIntersect( vec3 v0, vec3 v1, vec3 v2, vec3 v3, Ray r )
//----------------------------------------------------------------------------
{
	float tTri1 = TriangleIntersect( v0, v1, v2, r );
	float tTri2 = TriangleIntersect( v0, v2, v3, r );
	return min(tTri1, tTri2);
}


// TERRAIN

#define TERRAIN_FAR 100000.0
#define TERRAIN_HEIGHT 3000.0 // terrain amplitude
#define TERRAIN_LIFT  -1500.0 // how much to lift/drop the entire terrain
#define TERRAIN_SAMPLE_SCALE 0.00001

float lookup_Heightmap( in vec3 pos )
{
	vec2 uv = pos.xz;
	uv *= TERRAIN_SAMPLE_SCALE;
	float h = 0.0;
	float mult = 1.0;
	float scaleAccum = mult;

	for (int i = 0; i < 2; i ++)
	{
		h += mult * texture2D(t_PerlinNoise, uv + 0.5).x;
		mult *= 0.5;
		scaleAccum += mult;
		uv *= 2.0;
	}
	return (h / scaleAccum) * TERRAIN_HEIGHT + TERRAIN_LIFT;	
}

float lookup_Normal( in vec3 pos )
{
	vec2 uv = pos.xz;
	uv *= TERRAIN_SAMPLE_SCALE;
	float h = 0.0;
	float mult = 1.0;
	float scaleAccum = mult;

	for (int i = 0; i < 9; i ++)
	{
		h += mult * texture2D(t_PerlinNoise, uv + 0.5).x;
		mult *= 0.5;
		scaleAccum += mult;
		uv *= 2.0;
	}
	return (h / scaleAccum) * TERRAIN_HEIGHT + TERRAIN_LIFT;
}

vec3 terrain_calcNormal( vec3 pos, float t )
{
	vec3 eps = vec3(1.0, 0.0, 0.0);
	
	return normalize( vec3( lookup_Normal(pos-eps.xyy) - lookup_Normal(pos+eps.xyy),
			  	eps.x * 2.0,
			  	lookup_Normal(pos-eps.yyx) - lookup_Normal(pos+eps.yyx) ) );
}

float TerrainIntersect( Ray r )
{
	vec3 pos = r.origin;
	vec3 dir = (r.direction);
	float h = 0.0;
	float t = 0.0;
	float epsilon = 1.0;
	
	for(int i = 0; i < 300; i++)
	{
		h = pos.y - lookup_Heightmap(pos);
		if (t > TERRAIN_FAR || h < epsilon) break;
		t += h * 0.5;
		pos += dir * h * 0.5; 
	}
	return (h <= epsilon) ? t : INFINITY;	    
}

bool isLightSourceVisible( vec3 pos, vec3 n, vec3 dirToLight)
{
	float h = 1.0;
	float t = 0.0;
	float terrainHeight = TERRAIN_HEIGHT * 1.5 + TERRAIN_LIFT;
	pos += n * 2.0; // large outdoor scene requires moving away from surface a lot, 
	// otherwise, black patches from incorrect self-shadowing occur on mobile due to less precision

	for(int i = 0; i < 300; i++)
	{
		h = pos.y - lookup_Heightmap(pos);
		pos += dirToLight * h;
		if ( pos.y > terrainHeight || h < 0.0) break;
	}

	return h >= 0.0;
}

// WATER
/* Credit: some of the following water code is borrowed from https://www.shadertoy.com/view/Ms2SD1 posted by user 'TDM' */

#define WATER_SAMPLE_SCALE 0.01 
#define WATER_WAVE_HEIGHT 20.0 // max height of water waves   
#define WATER_FREQ        0.5 // wave density: lower = spread out, higher = close together
#define WATER_CHOPPY      4.0 // smaller beachfront-type waves, they travel in parallel
#define WATER_SPEED       1.0 // how quickly time passes
#define M1  mat2(1.6, 1.2, -1.2, 1.6);

float hash( vec2 p )
{
	float h = dot(p,vec2(127.1,311.7));	
    	return fract(sin(h)*43758.5453123);
}

float noise( in vec2 p )
{
	vec2 i = floor( p );
	vec2 f = fract( p );	
	vec2 u = f*f*(3.0-2.0*f);
	return -1.0+2.0*mix( mix( hash( i + vec2(0.0,0.0) ), 
		     hash( i + vec2(1.0,0.0) ), u.x),
		mix( hash( i + vec2(0.0,1.0) ), 
		     hash( i + vec2(1.0,1.0) ), u.x), u.y);
}

float ocean_octave( vec2 uv, float choppy )
{
	uv += noise(uv);        
	vec2 wv = 1.0 - abs(sin(uv));
	vec2 swv = abs(cos(uv));    
	wv = mix(wv, swv, wv);
	return pow(1.0 - pow(wv.x * wv.y, 0.65), choppy);
}

float getOceanWaterHeight( vec3 p )
{
	float freq = WATER_FREQ;
	float amp = 1.0;
	float choppy = WATER_CHOPPY;
	float sea_time = uTime * WATER_SPEED;
	
	vec2 uv = p.xz * WATER_SAMPLE_SCALE; 
	//uv.x *= 0.75;
	float h, d = 0.0;    
	for(int i = 0; i < 1; i++)
	{        
		d =  ocean_octave((uv + sea_time) * freq, choppy);
		d += ocean_octave((uv - sea_time) * freq, choppy);
		h += d * amp;     
		uv *= M1; 
		freq *= 1.9; 
		amp *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
	}

	return h * WATER_WAVE_HEIGHT + uWaterLevel;
}

float getOceanWaterHeight_Detail( vec3 p )
{
	float freq = WATER_FREQ;
	float amp = 1.0;
	float choppy = WATER_CHOPPY;
	float sea_time = uTime * WATER_SPEED;
	
	vec2 uv = p.xz * WATER_SAMPLE_SCALE; 
	//uv.x *= 0.75;
	float h, d = 0.0;    
	for(int i = 0; i < 4; i++)
	{        
		d =  ocean_octave((uv + sea_time) * freq, choppy);
		d += ocean_octave((uv - sea_time) * freq, choppy);
		h += d * amp;     
		uv *= M1; 
		freq *= 1.9; 
		amp *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
	}

	return h * WATER_WAVE_HEIGHT + uWaterLevel;
}

/*
float ocean_map( vec2 p )
{
	float freq = OCEAN_FREQ;
	float amp = OCEAN_HEIGHT;
	float choppy = OCEAN_CHOPPY;
	float ocean_time = uTime * OCEAN_SPEED;
	p *= OCEAN_SAMPLE_SCALE;
        vec2 uv = p;
	float d = 0.0;
	float h = 0.0;

	//d += sin(mod(uv.x * 3.0 + (ocean_time * 20.0), TWO_PI)) * 2.0 + (smoothstep(-0.99, 0.99, sin(mod(uv.y * 2.0, TWO_PI))) - 0.5) * min(150.0, uTime * 10.0);
	//d = sin(2.0 * uv.x + (ocean_time * 20.0)) * 5.0;
	//d += sin(4.0 * uv.x + (ocean_time * 40.0)) * 2.0;   
	for(int i = 0; i < 4; i++)
	{        
		d += ocean_octave((uv + ocean_time) * freq, choppy);
		d += ocean_octave((uv - ocean_time) * freq, choppy);
		h += d * amp;        
		uv *= m2; freq *= 1.9; amp *= 0.5;
		//choppy = mix(choppy, 1.0, 0.2);
	}
	return h;
}
*/


float OceanIntersect( Ray r )
{
	vec3 pos = r.origin;
	vec3 dir = (r.direction);
	float h = 0.0;
	float t = 0.0;
	
	for(int i = 0; i < 200; i++)
	{
		h = abs(pos.y - getOceanWaterHeight(pos));
		if (t > TERRAIN_FAR || h < 1.0) break;
		t += h;
		pos += dir * h; 
	}
	return (h <= 1.0) ? t : INFINITY;
}

vec3 ocean_calcNormal( vec3 pos, float t )
{
	vec3 eps = vec3(1.0, 0.0, 0.0);
	
	return normalize( vec3( getOceanWaterHeight_Detail(pos-eps.xyy) - getOceanWaterHeight_Detail(pos+eps.xyy),
			  	eps.x * 2.0,
			  	getOceanWaterHeight_Detail(pos-eps.yyx) - getOceanWaterHeight_Detail(pos+eps.yyx) ) );
}


//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
float SceneIntersect( Ray r, inout Intersection intersec, bool checkWater )
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
{
	vec3 normal;
        float d, dw;
	float t = INFINITY;
	vec3 hitPos; 

	// Terrain
	d = TerrainIntersect( r );
	if (d < t)
	{
		t = d;
		hitPos = r.origin + r.direction * t;
		intersec.normal = terrain_calcNormal(hitPos, t);
		intersec.emission = vec3(0);
		intersec.color = vec3(0);
		intersec.type = TERRAIN;
	}
	
	if (!checkWater)
		return t;
        
        d = OceanIntersect( r );    
	
	if (d < t)
	{
                t = d;
                hitPos = r.origin + r.direction * d;
		intersec.normal = ocean_calcNormal(hitPos, t);
		intersec.emission = vec3(0);
		intersec.color = vec3(0.7,0.8,0.9);
		intersec.type = REFR;
	}
		
	return t;
}


//-----------------------------------------------------------------------
vec3 CalculateRadiance( Ray r, vec3 sunDirection, inout uvec2 seed )
//-----------------------------------------------------------------------
{
	vec3 randVec = vec3(rand(seed) * 2.0 - 1.0, rand(seed) * 2.0 - 1.0, rand(seed) * 2.0 - 1.0);
	Ray cameraRay = r;
	vec3 initialSkyColor = Get_Sky_Color(r, sunDirection);
	
	//Ray skyRay = Ray( r.origin * vec3(0.05), normalize(vec3(r.direction.x, abs(r.direction.y), r.direction.z)) );
	//float dc = SphereIntersect( 10000.0, vec3(skyRay.origin.x, -9800, skyRay.origin.z) + vec3(rand(seed) * 2.0), skyRay );
	//vec3 skyPos = skyRay.origin + skyRay.direction * dc;
	//vec4 cld = render_clouds(skyRay, skyPos, sunDirection);
	
	Intersection intersec;
	vec3 accumCol = vec3(0.0);
        vec3 mask = vec3(1.0);
	vec3 n, nl, x;
	vec3 firstX = vec3(TERRAIN_FAR);
	vec3 tdir;
	
	float nc, nt, Re;
	float t = INFINITY;
	float cameraUnderWaterValue = r.origin.y < getOceanWaterHeight(r.origin) ? 1.0 : 0.0;
	int previousIntersecType = -1;
	bool checkWater = true;
	bool skyHit = false;
	bool bounceIsSpecular = true;

	
        for (int depth = 0; depth < 2; depth++)
	{

		t = SceneIntersect(r, intersec, checkWater);
		
		// ray hits sky first
		if (t == INFINITY && depth == 0 )
		{
			accumCol = initialSkyColor;

			skyHit = true;
			//firstX = skyPos;
			
			break;	
		}
		
		
		// if ray bounced off of water and hits sky
		if ( t == INFINITY && previousIntersecType == REFR )
		{
			accumCol = mask * Get_Sky_Color(r, sunDirection);
			
			skyHit = true;
			//firstX = skyPos;
			
			break;	
		}
		
		
		// useful data 
		n = intersec.normal;
                nl = dot(n,r.direction) <= 0.0 ? normalize(n) : normalize(n * -1.0);
		x = r.origin + r.direction * t;
		
		if (depth == 0) 
			firstX = x;

		// ray hits terrain
		if (intersec.type == TERRAIN)
		{
			firstX = x;
			float rockNoise = texture2D(t_PerlinNoise, (0.0001 * x.xz) + 0.5).x;
			vec3 rockColor0 = vec3(0.2, 0.2, 0.2) * 0.01 * rockNoise;
			vec3 rockColor1 = vec3(0.2, 0.2, 0.2) * rockNoise;
			vec3 snowColor = vec3(0.7);
			vec3 up = vec3(0, 1, 0);
			vec3 randomSkyVec = normalize(vec3(randVec.x, abs(randVec.y), randVec.z));
			vec3 skyColor = clamp(Get_Sky_Color(Ray(x, randomSkyVec), sunDirection), 0.0, 1.0);
			vec3 sunColor = clamp(Get_Sky_Color(Ray(x, normalize(sunDirection + (randVec * 0.02))), sunDirection), 0.0, 1.0);
			vec3 ambientColor;
			float terrainLayer = clamp( ((x.y + -TERRAIN_LIFT) + (rockNoise * 1000.0) * n.y) / (TERRAIN_HEIGHT * 1.0), 0.0, 1.0 );

			if (x.y > uWaterLevel)
			{

				if (terrainLayer > 0.66 && terrainLayer > 0.9 - n.y)
				{
					intersec.color = snowColor;
					ambientColor = skyColor * max(0.0, dot(up, n)); // ambient color from sky light
					n = normalize(mix(n, sunDirection, terrainLayer * 0.5));
				}	
				else
				{
					
					if (cameraUnderWaterValue == 0.0 && rand(seed) < 0.05)
					{
						r = Ray( x, reflect(r.direction, vec3(n.x, abs(n.y), n.z)) );
						accumCol = Get_Sky_Color(r, sunDirection);
						break;
					}
					
					intersec.color = mix(rockColor0, rockColor1, clamp(terrainLayer * n.y, 0.0, 1.0) );
					ambientColor = intersec.color * skyColor * max(0.0, dot(randomSkyVec, n)); // ambient color from sky light
				}		
			}
			accumCol = ambientColor;

			vec3 shadowRayDirection = normalize(sunDirection + (randomSkyVec * max(dot(sunDirection, up), 0.1)));						
			if ( isLightSourceVisible(x, n, shadowRayDirection) ) // in direct sunlight
			{
				accumCol = intersec.color * sunColor * max(0.0, dot(n, normalize(sunDirection + (randVec * 0.01))));	
			}
				
			break;
		}

		
		if (intersec.type == REFR)  // Ideal dielectric REFRACTION
		{
			checkWater = false;
			skyHit = false;

			nc = 1.0; // IOR of air
			nt = 1.33; // IOR of water
			Re = calcFresnelReflectance(n, nl, r.direction, nc, nt, tdir);

			if (cameraUnderWaterValue > 0.0)
				Re *= 1.0;
			else Re *= 2.0; // tweak to add more reflectivity to water

			if (rand(seed) < Re) // reflect ray from surface
			{
				r = Ray( x, reflect(r.direction, nl) );
				r.origin += r.direction;
				previousIntersecType = REFR;
				continue;	
			}
			else // transmit ray through surface
			{
				mask *= intersec.color;
				r = Ray(x, tdir);
				r.origin += r.direction;
				previousIntersecType = REFR;
				continue;
			}
		} // end if (intersec.type == REFR)
		
	} // end for (int depth = 0; depth < 2; depth++)
	
	
	// atmospheric haze effect (aerial perspective)
	float fogStartDistance = TERRAIN_FAR * 0.3;
	float hitDistance = distance(cameraRay.origin, firstX);
	float fogDistance;

	if ( skyHit ) // sky and clouds
	{
		//vec3 cloudColor = cld.rgb / (cld.a + 0.00001);
		//vec3 sunColor = clamp(Get_Sky_Color( Ray(skyPos, normalize((randVec * 0.03) + sunDirection)), sunDirection ), 0.0, 1.0);
		//cloudColor *= mix(sunColor, vec3(1), max(0.0, dot(vec3(0,1,0), sunDirection)) );
		//cloudColor = mix(initialSkyColor, cloudColor, clamp(cld.a, 0.0, 1.0));
		//accumCol = mask * mix( accumCol, cloudColor, clamp( exp2( -hitDistance * 0.003 ), 0.0, 1.0 ) );
		fogDistance = max(0.0, hitDistance - fogStartDistance);
		accumCol = mix( initialSkyColor, accumCol, clamp( exp(-(fogDistance * 0.00005)), 0.0, 1.0 ) );
	}	
	else // terrain and other objects
	{
		fogDistance = max(0.0, hitDistance - fogStartDistance);
		accumCol = mix( initialSkyColor, accumCol, clamp( exp(-(fogDistance * 0.00005)), 0.0, 1.0 ) );

		// underwater fog effect
		hitDistance *= cameraUnderWaterValue;
		accumCol = mix( vec3(0.0,0.001,0.001), accumCol, clamp( exp2( -hitDistance * 0.0005 ), 0.0, 1.0 ) );
	}
	
	
	return vec3(max(vec3(0), accumCol));      
}

/*
//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black        
	
}
*/

// tentFilter from Peter Shirley's 'Realistic Ray Tracing (2nd Edition)' book, pg. 60		
float tentFilter(float x)
{
	if (x < 0.5) 
		return sqrt(2.0 * x) - 1.0;
	else return 1.0 - sqrt(2.0 - (2.0 * x));
}

void main( void )
{
	// not needed, three.js has a built-in uniform named cameraPosition
	//vec3 camPos   = vec3( uCameraMatrix[3][0],  uCameraMatrix[3][1],  uCameraMatrix[3][2]);
	
    	vec3 camRight   = vec3( uCameraMatrix[0][0],  uCameraMatrix[0][1],  uCameraMatrix[0][2]);
    	vec3 camUp      = vec3( uCameraMatrix[1][0],  uCameraMatrix[1][1],  uCameraMatrix[1][2]);
	vec3 camForward = vec3(-uCameraMatrix[2][0], -uCameraMatrix[2][1], -uCameraMatrix[2][2]);
	
	// seed for rand(seed) function
	uvec2 seed = uvec2(uFrameCounter, uFrameCounter + 1.0) * uvec2(gl_FragCoord);

	vec2 pixelPos = vec2(0);
	vec2 pixelOffset = vec2(0);
	
	float x = rand(seed);
	float y = rand(seed);

	//if (!uCameraIsMoving)
	{
		pixelOffset.x = tentFilter(x);
		pixelOffset.y = tentFilter(y);
	}
	
	// pixelOffset ranges from -1.0 to +1.0, so only need to divide by half resolution
	pixelOffset /= (uResolution * 0.5);

	// vUv comes in the range 0.0 to 1.0, so we must map it to the range -1.0 to +1.0
	pixelPos = vUv * 2.0 - 1.0;
	pixelPos += pixelOffset;

	vec3 rayDir = normalize( pixelPos.x * camRight * uULen + pixelPos.y * camUp * uVLen + camForward );
	
	// depth of field
	vec3 focalPoint = uFocusDistance * rayDir;
	float randomAngle = rand(seed) * TWO_PI; // pick random point on aperture
	float randomRadius = rand(seed) * uApertureSize;
	vec3  randomAperturePos = ( cos(randomAngle) * camRight + sin(randomAngle) * camUp ) * randomRadius;
	// point on aperture to focal point
	vec3 finalRayDir = normalize(focalPoint - randomAperturePos);
    
	Ray ray = Ray( cameraPosition + randomAperturePos, finalRayDir );

	//SetupScene(); 

	// perform path tracing and get resulting pixel color
	vec3 pixelColor = CalculateRadiance( ray, uSunDirection, seed );
	
	vec3 previousColor = texture2D(tPreviousTexture, vUv).rgb;
	
	if ( uCameraIsMoving )
	{
		previousColor *= 0.85; // motion-blur trail amount (old image)
		pixelColor *= 0.15; // brightness of new image (noisy)
	}
	else
	{
		previousColor *= 0.9; // motion-blur trail amount (old image)
		pixelColor *= 0.1; // brightness of new image (noisy)
	}
	
	
	out_FragColor = vec4( pixelColor + previousColor, 1.0 );	
}