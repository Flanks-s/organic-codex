#include <metal_stdlib>
using namespace metal;

struct BodyPresentationVertex { float4 position [[position]]; float2 uv; };
vertex BodyPresentationVertex bodyPresentVertex(uint index [[vertex_id]]) {
    const float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 p=positions[index];
    return {float4(p,0,1),float2((p.x+1)*0.5,(1-p.y)*0.5)};
}
// The render attachment performs the explicit RGBA -> BGRA channel layout conversion.
fragment float4 bodyPresentFragment(BodyPresentationVertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler sample(coord::normalized,address::clamp_to_edge,filter::nearest);
    return image.sample(sample,v.uv);
}

// Scalars and basis vectors match BodyProfile v2 (static longitude). Encoded sRGB is multiplied as in the board canvas.
float4 bodyMap(texture2d<float, access::sample> image, float u, float v) {
    constexpr sampler mapSampler(coord::normalized, address::repeat, filter::linear);
    float h=float(image.get_height());
    return image.sample(mapSampler,float2(u,clamp(v,0.5f/h,1.0f-0.5f/h)));
}
float4 ringMap(texture2d<float, access::sample> image, float rho, float inner, float outer) {
    if (rho<inner || rho>outer) return float4(0);
    constexpr sampler ringSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return image.sample(ringSampler,float2((rho-inner)/(outer-inner),0.5f));
}
float3 ellLocal(float3 v,float3 pole,float3 meridian,float3 east,float3 axes,float cp,float sp) {
    float bx=dot(v,east),by=dot(v,pole),bz=dot(v,meridian);
    return float3((bx*cp-bz*sp)/axes.x,by/axes.z,(bx*sp+bz*cp)/axes.y);
}
// Phase v1 uses actual surface normals; uniforms are shared with the CPU recipe.
float3 phaseColor(float3 source,float3 normal,float3 L,float2 point,constant float4* q) {
    float ndl=dot(normal,L),width=mix(q[14].z,q[12].w,q[10].y);
    float t=clamp((ndl+width/2)/width,0.0f,1.0f),day=t*t*(3-2*t);
    float limb=1-q[2].y*pow(1-max(0.0f,normal.z),2.0f);
    float3 base=max(source,float3(1));float lum=dot(base,float3(0.2126f,0.7152f,0.0722f));
    float3 night=mix(base*q[1].w,q[12].xyz*lum,q[10].z);
    float diffuse=q[11].z+q[11].w*sqrt(max(0.0f,ndl));
    float3 rgb=mix(night,base*diffuse*(1+q[11].y),day)*limb;
    float2 a=L.xy;float len=length(a);float2 d=len>0 ? a/len:float2(1,0);
    float position=dot(point,d),front=-1.3f+2.6f*q[10].w;
    float u=clamp((position-front+q[13].w)/(2*q[13].w),0.0f,1.0f);
    float sweep=q[10].w>=1 ? 1:(1-u*u*(3-2*u))*(q[10].w>0 ? 1:0);
    float3 blood=q[13].xyz*lum*limb*(0.75f+0.25f*position)*(1+q[11].y);
    rgb=mix(rgb,blood,sweep);
    if(q[11].x>=1) return float3((lum*limb*q[14].x+q[14].y)*limb);
    return mix(rgb,float3((lum*limb*q[14].x+q[14].y)*limb),q[11].x);
}
kernel void bodyRender(texture2d<float, access::sample> map [[texture(0)]],
                       texture2d<float, access::sample> ring [[texture(1)]],
                       texture2d<float, access::sample> clouds [[texture(2)]],
                       texture2d<float, access::write> output [[texture(3)]],
                       constant float4* q [[buffer(0)]], uint2 tid [[thread_position_in_grid]]) {
    int side=int(q[0].x), ss=int(q[0].y);
    if (tid.x>=uint(side) || tid.y>=uint(side)) return;
    float ratio=q[0].z,turn=q[0].w,center=float(side*ss)*0.5f,radius=center*ratio;
    float3 L=q[1].xyz;float night=q[1].w,soft=q[2].x,limb=q[2].y,rim=q[2].z,inner=q[2].w,outer=q[3].x;
    bool ringed=q[3].y>0,emit=q[3].z>0,ell=q[3].w>0,unlit=q[4].w>0;
    float3 axes=q[4].xyz,pole=q[5].xyz,meridian=q[6].xyz,east=q[7].xyz;
    float cp=cos(turn*2*M_PI_F),sp=sin(turn*2*M_PI_F),pL=dot(pole,L);
    float3 ex=ellLocal(float3(1,0,0),pole,meridian,east,axes,cp,sp),ey=ellLocal(float3(0,1,0),pole,meridian,east,axes,cp,sp),ez=ellLocal(float3(0,0,1),pole,meridian,east,axes,cp,sp);
    float A=dot(ez,ez);float4 total=0;
    for (int sy=0;sy<ss;sy++) for (int sx=0;sx<ss;sx++) {
        float x=(float(tid.x*ss+sx)+0.5f-center)/radius,y=(center-float(tid.y*ss+sy)-0.5f)/radius,r2=x*x+y*y,r=sqrt(r2);
        float clip=clamp(center-r*radius+0.5f,0.0f,1.0f);
        if (clip<=0) continue;
        float alpha=0,u=0,v=0;float3 normal=0;
        if (ell) {
            float3 origin=x*ex+y*ey;float B=-2*dot(origin,ez),C=dot(origin,origin)-1,disc=C-B*B/(4*A);
            alpha=clamp(-disc*radius/2+0.5f,0.0f,1.0f);
            if (alpha>0) {
                float t=disc<0 ? (-B-sqrt(max(0.0f,B*B-4*A*C)))/(2*A) : -B/(2*A);
                float3 surface=normalize(origin-t*ez);
                float X=surface.x/axes.x,Y=surface.y/axes.z,Z=surface.z/axes.y,bx=X*cp+Z*sp,bz=-X*sp+Z*cp;
                normal=normalize(bx*east+Y*pole+bz*meridian);
                u=0.5f+atan2(surface.x,surface.z)/(2*M_PI_F);v=0.5f-asin(clamp(surface.y,-1.0f,1.0f))/M_PI_F;
            }
        } else {
            alpha=clamp((1-r)*radius+0.5f,0.0f,1.0f);
            if (alpha>0) {
                normal=r>=1 ? float3(x/max(r,0.001f),y/max(r,0.001f),0) : float3(x,y,sqrt(max(0.0f,1-r2)));
                u=0.5f+atan2(dot(normal,east),dot(normal,meridian))/(2*M_PI_F)-turn;
                v=0.5f-asin(clamp(dot(normal,pole),-1.0f,1.0f))/M_PI_F;
            }
        }
        float3 rgb=0;
        if (alpha>0) {
            if(q[9].y>0) normal=normalize(float3(normal.xy,max(0.0f,normal.z)));
            rgb=bodyMap(map,u,v).rgb*255;
            if (q[9].x>0) {float cloudU=q[9].z>0 ? u+q[9].w:u-turn*0.08f;float c=bodyMap(clouds,cloudU,v).x*0.85f;rgb+=(float3(240,242,245)-rgb)*c;}
            float ndl=dot(normal,L),k=clamp((ndl+soft/2)/soft,0.0f,1.0f),day=k*k*(3-2*k);
            float shade=unlit ? 1 : emit ? 0.58f+0.42f*pow(max(0.0f,normal.z),0.45f) : (night+(1-night)*day*(0.62f+0.38f*max(0.0f,ndl)))*(1-limb*pow(1-max(0.0f,normal.z),2.0f));
            if (ringed && !unlit && pL>0.02f) {float t=-dot(normal,pole)/pL;if (t>0) shade*=1-0.7f*ringMap(ring,length(normal+t*L),inner,outer).w;}
            if (q[9].y>0) {
                float shadow=1;
                if (ringed && !unlit && pL>0.02f) {float t=-dot(normal,pole)/pL;if(t>0) shadow=1-0.7f*ringMap(ring,length(normal+t*L),inner,outer).w;}
                rgb=phaseColor(rgb,normal,L,float2(x,y),q)*shadow;
            } else {rgb*=shade;}
            float atmosphereGain=1; if(q[9].y>0) atmosphereGain=(1-q[11].x)*(1-q[10].w);
            if (q[8].w>0 && !unlit) {float w=clamp((r-(1-rim))/rim,0.0f,1.0f),dl=clamp((ndl+0.25f)/0.5f,0.0f,1.0f);rgb+=q[8].xyz*w*w*(0.25f+0.75f*dl)*0.7f*atmosphereGain;}
        }
        float4 pixel=float4(rgb*alpha,alpha);
        if (ringed && abs(pole.z)>0.00001f) {
            float z=-(pole.x*x+pole.y*y)/pole.z,rho=sqrt(r2+z*z);float4 sample=ringMap(ring,rho,inner,outer);
            if (sample.w>0.01f) {
                float d=dot(float3(x,y,z),L),perp=rho*rho-d*d;
                // The same projected radius as the CPU avoids cancellation at the planet's shadow boundary.
                if(q[9].y>0 && L.x==0 && L.y==0) perp=r2;
                float lit=unlit ? 1 : d<0 && perp<1 ? 0.16f:0.95f,a=sample.w*0.92f*clip;
                bool front=!(r<1 && z<sqrt(max(0.0f,1-r2)));
                float3 ringRGB=sample.rgb*255*lit;
                if(q[9].y>0) ringRGB=phaseColor(sample.rgb*255,pole.z>0 ? pole:-pole,L,float2(x,y),q)*lit;
                float4 ringPixel=float4(ringRGB*a,a);
                pixel=front ? ringPixel+pixel*(1-a) : pixel+ringPixel*(1-alpha);
            }
        }
        total+=pixel*clip;
    }
    total/=float(ss*ss);
    if(q[9].y>0 && q[15].x>0) total.r+=q[15].x*q[10].w*(255*total.w-total.r);
    output.write(clamp(float4(total.rgb/255,total.w),0.0f,1.0f),tid);
}
