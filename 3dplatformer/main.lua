-- GPU-based low-poly fantasy RPG prototype for LÖVE 11.x
-- GPU: transforms, perspective projection, triangle rasterization, depth testing.
-- CPU/Lua: gameplay and assembling low-poly character parts.
-- Controls: WASD move | Q/E orbit camera | J attack | Shift run | Esc quit

local shader, cubeMesh, sphereMesh, coneMesh, cylinderMesh, surfaceTexture
local player, enemies
local yaw, facing, walkTime = 0, 0, 0
local cameraPitch = -0.12
local cameraX, cameraY, cameraZ
local velocityX, velocityZ = 0, 0
local verticalVelocity = 0
local grounded = true
local cameraDistance = 7.5
local cameraSmooth = 10
local acceleration = 18
local groundFriction = 14
local airControl = 0.42
local attackTimer, attackCooldown = 0, 0
local message, messageTimer = "Explore the ruins. Defeat the guardians!", 4
local SW, SH = 960, 640

local vertexShader = [[
uniform mat4 uProjection;
uniform mat4 uView;
uniform mat4 uModel;
attribute vec3 VertexNormal;
varying vec4 vColor;
varying vec3 vWorldPos;
varying vec3 vNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec4 world = uModel * vertex_position;
    vWorldPos = world.xyz;
    vNormal = normalize(mat3(uModel) * VertexNormal);
    vColor = VertexColor;
    return uProjection * uView * world;
}
]]

local pixelShader = [[
uniform Image uSurfaceTexture;
uniform vec3 uLightDirection;
varying vec4 vColor;
varying vec3 vWorldPos;
varying vec3 vNormal;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec3 n = normalize(vNormal);
    vec3 lightDir = normalize(-uLightDirection);
    float diffuse = max(dot(n, lightDir), 0.0);
    float lighting = 0.38 + diffuse * 0.72;

    // World-space tiled texture: works on all procedural meshes without UV authoring.
    vec2 uv = vWorldPos.xz * 0.16;
    vec4 surface = Texel(uSurfaceTexture, uv);

    // Gentle texture influence keeps the original material palette readable.
    vec3 base = vColor.rgb * color.rgb;
    vec3 textured = mix(base * 0.88, base * surface.rgb * 1.20, 0.48);
    return vec4(textured * lighting, vColor.a * color.a);
}
]]

local function identity()
    return {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}
end

local function multiply(a,b)
    local out={}
    for col=0,3 do
        for row=0,3 do
            local sum=0
            for k=0,3 do sum=sum+a[k*4+row+1]*b[col*4+k+1] end
            out[col*4+row+1]=sum
        end
    end
    return out
end

local function translation(x,y,z)
    local m=identity()
    m[13],m[14],m[15]=x,y,z
    return m
end

local function scaleMatrix(x,y,z)
    return {x,0,0,0, 0,y,0,0, 0,0,z,0, 0,0,0,1}
end

local function rotationY(a)
    local c,s=math.cos(a),math.sin(a)
    return {c,0,-s,0, 0,1,0,0, s,0,c,0, 0,0,0,1}
end

local function modelMatrix(x,y,z,sx,sy,sz,rot)
    return multiply(translation(x,y,z),
        multiply(rotationY(rot or 0),scaleMatrix(sx,sy,sz)))
end

local function perspective(fov,aspect,near,far)
    local f=1/math.tan(fov*0.5)
    return {f/aspect,0,0,0, 0,f,0,0,
        0,0,(far+near)/(near-far),-1,
        0,0,(2*far*near)/(near-far),0}
end

local function dot(ax,ay,az,bx,by,bz)
    return ax*bx+ay*by+az*bz
end

local function viewMatrix(px,py,pz,yawAngle,pitch)
    local cy,sy=math.cos(yawAngle),math.sin(yawAngle)
    local cp,sp=math.cos(pitch),math.sin(pitch)
    local fx,fy,fz=sy*cp,sp,cy*cp
    local rx,ry,rz=cy,0,-sy
    -- Up points upward; this cross product order avoids an inverted view.
    local ux=fy*rz-fz*ry
    local uy=fz*rx-fx*rz
    local uz=fx*ry-fy*rx
    return {
        rx,ux,-fx,0, ry,uy,-fy,0, rz,uz,-fz,0,
        -dot(rx,ry,rz,px,py,pz),
        -dot(ux,uy,uz,px,py,pz),
         dot(fx,fy,fz,px,py,pz),1
    }
end

local function color(r,g,b) return {r/255,g/255,b/255,1} end

local function makeCube()
    local verts={}
    local function face(a,b,c,d,col)
        local ux,uy,uz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
        local vx,vy,vz=c[1]-a[1],c[2]-a[2],c[3]-a[3]
        local nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
        local len=math.sqrt(nx*nx+ny*ny+nz*nz)
        nx,ny,nz=nx/len,ny/len,nz/len
        for _,p in ipairs({a,b,c,a,c,d}) do
            verts[#verts+1]={p[1],p[2],p[3],col[1],col[2],col[3],1,nx,ny,nz}
        end
    end
    face({-.5,-.5,.5},{.5,-.5,.5},{.5,.5,.5},{-.5,.5,.5},color(190,177,148))
    face({.5,-.5,-.5},{-.5,-.5,-.5},{-.5,.5,-.5},{.5,.5,-.5},color(130,124,108))
    face({-.5,-.5,-.5},{-.5,-.5,.5},{-.5,.5,.5},{-.5,.5,-.5},color(155,147,126))
    face({.5,-.5,.5},{.5,-.5,-.5},{.5,.5,-.5},{.5,.5,.5},color(112,108,96))
    face({-.5,.5,.5},{.5,.5,.5},{.5,.5,-.5},{-.5,.5,-.5},color(205,192,162))
    face({-.5,-.5,-.5},{.5,-.5,-.5},{.5,-.5,.5},{-.5,-.5,.5},color(82,78,69))
    return love.graphics.newMesh({
        {"VertexPosition","float",3},{"VertexColor","float",4},
        {"VertexNormal","float",3}
    },verts,"triangles","static")
end

local function makeSphere()
    local verts={}
    local rings,segments=8,12
    for r=0,rings-1 do
        local t1=-math.pi/2+math.pi*r/rings
        local t2=-math.pi/2+math.pi*(r+1)/rings
        for s=0,segments-1 do
            local a1=2*math.pi*s/segments
            local a2=2*math.pi*(s+1)/segments
            local function point(t,a)
                return {math.cos(t)*math.cos(a),math.sin(t),math.cos(t)*math.sin(a)}
            end
            local p1,p2,p3,p4=point(t1,a1),point(t1,a2),point(t2,a2),point(t2,a1)
            for _,p in ipairs({p1,p2,p3,p1,p3,p4}) do
                -- A subtle per-vertex variation gives the low-poly surface some depth.
                local shade=0.82+0.18*math.max(0,p[1]*0.3+p[2]*0.7+p[3]*0.4)
                verts[#verts+1]={p[1],p[2],p[3],shade,shade,shade,1,p[1],p[2],p[3]}
            end
        end
    end
    return love.graphics.newMesh({
        {"VertexPosition","float",3},{"VertexColor","float",4},
        {"VertexNormal","float",3}
    },verts,"triangles","static")
end

local function makeCone()
    local verts={}
    local segments=10
    for i=0,segments-1 do
        local a1=2*math.pi*i/segments
        local a2=2*math.pi*(i+1)/segments
        local p1={math.cos(a1),-0.5,math.sin(a1)}
        local p2={math.cos(a2),-0.5,math.sin(a2)}
        local tip={0,0.5,0}
        local shade=0.78+0.2*math.cos((a1+a2)/2)
        for _,p in ipairs({p1,p2,tip}) do
            local nx,ny,nz=p[1],0.45,p[3]
            local nl=math.sqrt(nx*nx+ny*ny+nz*nz)
            verts[#verts+1]={p[1],p[2],p[3],shade,shade,shade,1,nx/nl,ny/nl,nz/nl}
        end
    end
    return love.graphics.newMesh({
        {"VertexPosition","float",3},{"VertexColor","float",4},
        {"VertexNormal","float",3}
    },verts,"triangles","static")
end

local function makeCylinder()
    local verts={}
    local segments=12
    for i=0,segments-1 do
        local a1=2*math.pi*i/segments
        local a2=2*math.pi*(i+1)/segments
        local p1={math.cos(a1),-0.5,math.sin(a1)}
        local p2={math.cos(a2),-0.5,math.sin(a2)}
        local p3={math.cos(a2),0.5,math.sin(a2)}
        local p4={math.cos(a1),0.5,math.sin(a1)}
        local shade=0.72+0.24*math.max(0,math.cos((a1+a2)/2))
        for _,p in ipairs({p1,p2,p3,p1,p3,p4}) do
            local nx,nz=p[1],p[3]
            local nl=math.sqrt(nx*nx+nz*nz)
            verts[#verts+1]={p[1],p[2],p[3],shade,shade,shade,1,nx/nl,0,nz/nl}
        end
        -- top cap
        for _,p in ipairs({{0,0.5,0},p4,p3}) do
            verts[#verts+1]={p[1],p[2],p[3],0.88,0.88,0.88,1,0,1,0}
        end
        -- bottom cap
        for _,p in ipairs({{0,-0.5,0},p2,p1}) do
            verts[#verts+1]={p[1],p[2],p[3],0.48,0.48,0.48,1,0,-1,0}
        end
    end
    return love.graphics.newMesh({
        {"VertexPosition","float",3},{"VertexColor","float",4},
        {"VertexNormal","float",3}
    },verts,"triangles","static")
end

local function drawMesh(mesh,x,y,z,sx,sy,sz,rot,tint)
    shader:send("uModel","column",modelMatrix(x,y,z,sx,sy,sz,rot or 0))
    love.graphics.setColor(tint and tint[1] or 1,tint and tint[2] or 1,
        tint and tint[3] or 1,1)
    love.graphics.draw(mesh)
end

local function drawBox(x,y,z,sx,sy,sz,rot,tint)
    drawMesh(cubeMesh,x,y,z,sx,sy,sz,rot,tint)
end

local function drawColumn(x,z,height)
    -- Broad base, faceted shaft, decorative rings, fluted ribs and capital.
    drawBox(x,0.20,z,1.35,0.40,1.35,0,{0.36,0.35,0.31})
    drawBox(x,0.42,z,1.12,0.12,1.12,0,{0.58,0.55,0.47})
    drawMesh(cylinderMesh,x,0.52+height*0.5,z,0.82,height,0.82,0,{0.74,0.72,0.65})
    for k=1,8 do
        local a=2*math.pi*k/8
        local rx,rz=math.cos(a)*0.39,math.sin(a)*0.39
        drawMesh(cylinderMesh,x+rx,0.52+height*0.5,z+rz,0.09,height*0.98,0.09,0,{0.57,0.55,0.49})
    end
    drawBox(x,0.60+height,z,1.15,0.16,1.15,0,{0.50,0.47,0.40})
    drawBox(x,0.74+height,z,1.40,0.20,1.40,0,{0.70,0.66,0.57})
    drawBox(x,0.86+height,z,1.12,0.08,1.12,0,{0.39,0.37,0.32})
end

local function drawArch(x,z)
    drawColumn(x-2,z,1.85)
    drawColumn(x+2,z,2.05)
    -- Multiple lintel layers and broken stone blocks.
    drawBox(x,3.05,z,5.35,0.52,1.48,0,{0.62,0.59,0.51})
    drawBox(x,3.34,z,5.55,0.16,1.58,0,{0.74,0.70,0.60})
    drawBox(x-1.55,3.53,z,1.25,0.22,1.35,0.06,{0.53,0.51,0.45})
    drawBox(x+0.30,3.58,z,1.35,0.26,1.30,-0.05,{0.66,0.63,0.54})
    drawBox(x+1.62,3.43,z,0.85,0.18,1.25,0.04,{0.45,0.43,0.38})
    -- Ivy strands and leaf clusters on the column faces.
    for i=0,4 do
        local yy=0.9+i*0.43
        drawBox(x-2.48,yy,z+0.12,0.12,0.10,0.62,0,{0.16,0.35,0.13})
        drawBox(x-2.35,yy+0.10,z+0.18,0.26,0.10,0.20,0.35,{0.22,0.48,0.18})
        drawBox(x+2.48,yy+0.12,z-0.10,0.12,0.10,0.60,0,{0.16,0.35,0.13})
        drawBox(x+2.34,yy+0.20,z-0.16,0.24,0.10,0.22,-0.35,{0.23,0.50,0.18})
    end
end

local function drawShrine()
    -- A distant shrine adds a focal point behind the arches.
    drawBox(0,0.25,23,4.2,0.5,2.0,0,{0.48,0.45,0.39})
    drawBox(0,0.58,23,3.5,0.18,1.7,0,{0.69,0.65,0.55})
    drawBox(-1.35,1.20,23,0.42,1.2,0.55,0,{0.58,0.55,0.48})
    drawBox(1.35,1.20,23,0.42,1.2,0.55,0,{0.58,0.55,0.48})
    drawBox(0,1.85,23,3.2,0.28,0.95,0,{0.72,0.67,0.57})
    drawMesh(coneMesh,0,2.42,23,0.70,1.15,0.70,0,{0.88,0.38,0.75})
    drawMesh(sphereMesh,0,2.05,23,0.50,0.48,0.50,0,{0.98,0.62,0.88})
end

local function drawGrassAndPlants()
    for i=-5,5 do
        if i~=0 then
            local x=i*1.55
            local z=4+(i%3)*5
            drawMesh(coneMesh,x,0.45,z,0.20,0.90,0.20,0.2,{0.20,0.43,0.16})
            drawMesh(coneMesh,x+0.18,0.35,z+0.10,0.16,0.65,0.16,-0.3,{0.29,0.52,0.18})
            drawMesh(coneMesh,x-0.14,0.32,z-0.08,0.15,0.58,0.15,0.4,{0.15,0.35,0.13})
        end
    end
end

local function drawHero()
    local x,z,a=player.x,player.z,facing
    -- Offset every character part vertically while jumping, without rewriting each part.
    local baseDrawBox = drawBox
    local baseDrawMesh = drawMesh
    drawBox = function(px, py, pz, sx, sy, sz, rot, tint)
        return baseDrawBox(px, py + (player.y or 0), pz, sx, sy, sz, rot, tint)
    end
    drawMesh = function(mesh, px, py, pz, sx, sy, sz, rot, tint)
        return baseDrawMesh(mesh, px, py + (player.y or 0), pz, sx, sy, sz, rot, tint)
    end
    local moving=love.keyboard.isDown("w","a","s","d")
    local stride=moving and math.sin(walkTime*9)*0.13 or 0
    local green={0.10,0.42,0.20}
    local greenLight={0.17,0.56,0.27}
    local skin={0.91,0.68,0.48}
    local skinShade={0.72,0.46,0.30}
    local hair={0.90,0.72,0.22}
    local hairDark={0.62,0.39,0.10}
    local brown={0.28,0.14,0.07}
    local leather={0.40,0.23,0.10}
    local gold={0.95,0.69,0.12}
    local red={0.72,0.08,0.12}
    local steel={0.78,0.86,0.92}
    local a2=a

    -- Boots, legs and tunic hem.
    drawBox(x-0.17,0.12+stride,z+0.08,0.30,0.22,0.42,a2,brown)
    drawBox(x+0.17,0.12-stride,z+0.08,0.30,0.22,0.42,a2,brown)
    drawBox(x-0.17,0.39+stride,z,0.23,0.42,0.25,a2,leather)
    drawBox(x+0.17,0.39-stride,z,0.23,0.42,0.25,a2,leather)
    drawBox(x-0.17,0.29+stride,z+0.135,0.25,0.07,0.27,a2,{0.58,0.34,0.14})
    drawBox(x+0.17,0.29-stride,z+0.135,0.25,0.07,0.27,a2,{0.58,0.34,0.14})
    drawBox(x,0.68,z,0.68,0.34,0.48,a2,green)
    drawBox(x,0.53,z+0.005,0.70,0.08,0.50,a2,red) -- red tunic edging
    -- Short red travel cape, visible behind the shoulders.
    drawBox(x,1.12,z-0.27,0.58,0.66,0.12,a2,{0.56,0.08,0.10})
    drawBox(x,0.82,z-0.28,0.52,0.18,0.14,a2,{0.72,0.12,0.12})

    -- Torso, collar, shoulder pads and sleeves.
    drawBox(x,1.02,z,0.68,0.70,0.43,a2,green)
    drawBox(x,1.38,z+0.015,0.34,0.12,0.46,a2,{0.12,0.30,0.13})
    drawBox(x-0.40,1.18,z,0.27,0.25,0.32,a2,greenLight)
    drawBox(x+0.40,1.18,z,0.27,0.25,0.32,a2,greenLight)
    drawBox(x-0.40,1.29,z+0.02,0.29,0.13,0.34,a2,gold)
    drawBox(x+0.40,1.29,z+0.02,0.29,0.13,0.34,a2,gold)
    drawBox(x-0.44,0.91,z,0.20,0.48,0.22,a2,green)
    drawBox(x+0.44,0.91,z,0.20,0.48,0.22,a2,green)
    drawBox(x-0.44,0.63,z+0.02,0.17,0.16,0.18,a2,skin)
    drawBox(x+0.44,0.63,z+0.02,0.17,0.16,0.18,a2,skin)

    -- Belt, buckle and diagonal chest strap.
    drawBox(x,0.79,z-0.01,0.72,0.12,0.47,a2,leather)
    drawBox(x-0.43,0.79,z+0.02,0.18,0.20,0.20,a2,{0.48,0.29,0.12}) -- belt pouch
    drawBox(x,0.79,z+0.247,0.13,0.13,0.035,a2,gold)
    drawBox(x,1.08,z+0.253,0.12,0.24,0.035,a2,gold) -- chest crest
    drawBox(x,1.08,z+0.275,0.06,0.15,0.025,a2,red)
    drawBox(x-0.14,1.15,z+0.235,0.075,0.48,0.035,-0.32,leather)
    drawBox(x-0.14,1.15,z+0.257,0.035,0.38,0.025,-0.32,gold)

    -- Head, ears, nose, eyes and hair. Sphere meshes soften the silhouette.
    drawMesh(sphereMesh,x,1.68,z,0.39,0.44,0.34,a2,skin)
    drawBox(x-0.385,1.68,z,0.10,0.15,0.13,a2,skinShade)
    drawBox(x+0.385,1.68,z,0.10,0.15,0.13,a2,skin)
    drawBox(x,1.62,z+0.32,0.09,0.10,0.12,a2,skinShade)
    drawBox(x-0.13,1.72,z+0.302,0.075,0.055,0.035,a2,{0.10,0.12,0.12})
    drawBox(x+0.13,1.72,z+0.302,0.075,0.055,0.035,a2,{0.10,0.12,0.12})
    drawMesh(sphereMesh,x,1.91,z-0.015,0.40,0.22,0.36,a2,hair)
    drawBox(x-0.20,1.84,z+0.22,0.16,0.12,0.17,a2,hairDark)
    drawBox(x+0.18,1.84,z+0.22,0.16,0.12,0.17,a2,hairDark)

    -- Long green adventurer cap, tilted backward slightly.
    drawMesh(coneMesh,x,2.20,z-0.12,0.33,0.72,0.32,a2-0.10,green)
    drawBox(x,1.99,z+0.01,0.46,0.10,0.42,a2,greenLight)

    -- Red scabbard on the back.
    drawBox(x-0.28,1.28,z-0.20,0.14,0.82,0.18,a2-0.28,red)
    drawBox(x-0.28,1.68,z-0.20,0.22,0.10,0.22,a2-0.28,gold)

    -- Right arm and articulated sword. The arm swings during the attack.
    local progress=attackTimer>0 and 1-attackTimer/0.38 or 0
    local swing=attackTimer>0 and math.sin(progress*math.pi) or 0
    drawBox(x+0.44,0.98,z,0.20,0.45,0.22,a2-swing*0.8,green)
    drawBox(x+0.45,0.71,z+0.04,0.16,0.15,0.17,a2-swing*0.8,skin)
    local sa=a2+0.62-swing*1.5
    local dx,dz=math.cos(sa),-math.sin(sa)
    drawBox(x+0.47+dx*0.13,0.76,z+0.06+dz*0.13,0.13,0.12,0.28,sa,leather)
    drawBox(x+0.47+dx*0.13,0.76,z+0.06+dz*0.13,0.30,0.08,0.09,sa,gold)
    drawBox(x+0.47+dx*0.54,0.81,z+0.06+dz*0.54,0.095,0.10,0.78,sa,steel)
    drawBox(x+0.47+dx*0.92,0.81,z+0.06+dz*0.92,0.055,0.065,0.20,sa,{0.92,0.95,0.98})
    drawBox = baseDrawBox
    drawMesh = baseDrawMesh
end

local function drawEnemy(e)
    local a = e.facing or 0
    local red = e.flash > 0 and {1,0.92,0.65} or {0.62,0.16,0.14}
    local lunge = (e.state == "attack") and 0.22 or 0
    local dodge = (e.state == "dodge") and ((e.dodgeDir or 1) * 0.24) or 0
    local armColor = (e.state == "block") and {0.72,0.75,0.80} or {0.48,0.10,0.10}
    drawBox(e.x+dodge,0.40,e.z,0.52,0.78,0.40,a,red)
    drawBox(e.x+dodge,0.98,e.z,0.40,0.36,0.36,a,{0.85,0.58,0.39})
    drawBox(e.x+dodge,0.99,e.z+0.20,0.22,0.08,0.06,a,{0.08,0.07,0.06})
    drawBox(e.x-0.34+dodge+lunge,0.48,e.z+lunge,0.17,0.55,0.18,a,armColor)
    drawBox(e.x+0.34+dodge+lunge,0.48,e.z+lunge,0.17,0.55,0.18,a,armColor)
    if e.state == "windup" then
        drawBox(e.x,1.48,e.z,0.16,0.16,0.16,0,{1.0,0.78,0.12})
    elseif e.state == "block" then
        drawBox(e.x,1.22,e.z+0.34,0.42,0.42,0.10,a,{0.65,0.72,0.82})
    elseif e.state == "dodge" then
        drawBox(e.x+dodge,1.48,e.z,0.10,0.10,0.10,0,{0.35,0.85,1.0})
    end
end

local function startAttack()
    if attackCooldown<=0 then
        attackTimer,attackCooldown=0.38,0.48
        message,messageTimer="Sword swing!",0.7
    end
end

local function makeSurfaceTexture()
    -- Small seamless-ish stone/soil texture generated locally; no external assets required.
    local size=64
    local data=love.image.newImageData(size,size)
    math.randomseed(37)
    for y=0,size-1 do
        for x=0,size-1 do
            local cellX=math.floor(x/8)
            local cellY=math.floor(y/8)
            local mortar=(x%8==0 or y%8==0) and 0.58 or 1.0
            local noise=0.84+math.random()*0.22
            local grain=((x*13+y*7)%11==0) and 0.72 or 1.0
            local variation=noise*mortar*grain
            local r=math.min(1,0.68*variation)
            local g=math.min(1,0.66*variation)
            local b=math.min(1,0.60*variation)
            data:setPixel(x,y,r,g,b,1)
        end
    end
    local img=love.graphics.newImage(data)
    img:setFilter("linear","linear")
    img:setWrap("repeat","repeat")
    return img
end

function love.load()
    love.window.setMode(SW,SH,{depth=24,vsync=1})
    love.window.setTitle("Lua GPU 3D RPG - Detailed Adventurer")
    love.graphics.setDefaultFilter("nearest","nearest")
    shader=love.graphics.newShader(pixelShader,vertexShader)
    surfaceTexture=makeSurfaceTexture()
    shader:send("uSurfaceTexture",surfaceTexture)
    shader:send("uLightDirection",{ -0.45, -1.0, -0.25 })
    cubeMesh=makeCube()
    sphereMesh=makeSphere()
    coneMesh=makeCone()
    cylinderMesh=makeCylinder()
    love.graphics.setDepthMode("less",true)
    love.graphics.setMeshCullMode("none")

    player={x=0,y=0,z=0,health=100}
    enemies={
        {x=-4,z=8,health=3,alive=true,flash=0,state="idle",attackTimer=0,cooldown=0,
         dodgeCooldown=0,blockTimer=0,aiId=1},
        {x=4,z=13,health=3,alive=true,flash=0,state="idle",attackTimer=0,cooldown=0,
         dodgeCooldown=0,blockTimer=0,aiId=2},
        {x=0,z=19,health=3,alive=true,flash=0,state="idle",attackTimer=0,cooldown=0,
         dodgeCooldown=0,blockTimer=0,aiId=3}
    }
end

function love.keypressed(key)
    if key == "k" then startAttack() end

    -- Jump only when standing on the ground.
    if key == "space" and grounded then
        verticalVelocity = 7.0
        grounded = false
    end

    if key == "escape" then love.event.quit() end
end

function love.update(dt)
    dt=math.min(dt,0.05)
    walkTime=walkTime+dt
    attackTimer=math.max(0,attackTimer-dt)
    attackCooldown=math.max(0,attackCooldown-dt)
    messageTimer=math.max(0,messageTimer-dt)
    -- Camera rotation is independent from the character.
    -- A/D rotate the camera; Up/Down arrows adjust camera pitch.
    if love.keyboard.isDown("a") then yaw = yaw - dt * 1.8 end
    if love.keyboard.isDown("d") then yaw = yaw + dt * 1.8 end
    if love.keyboard.isDown("up") then
        cameraPitch = math.min(0.28, cameraPitch + dt * 0.8)
    end
    if love.keyboard.isDown("down") then
        cameraPitch = math.max(-0.65, cameraPitch - dt * 0.8)
    end

    -- W/S move forward/back relative to camera; J/L strafe left/right.
    local f, s = 0, 0
    if love.keyboard.isDown("w") then f = f + 1 end
    if love.keyboard.isDown("s") then f = f - 1 end
    if love.keyboard.isDown("l") then s = s + 1 end
    if love.keyboard.isDown("j") then s = s - 1 end

    local inputLen = math.sqrt(f*f + s*s)
    if inputLen > 0 then f, s = f/inputLen, s/inputLen end

    local forwardX, forwardZ = math.sin(yaw), math.cos(yaw)
    local rightX, rightZ = math.cos(yaw), -math.sin(yaw)
    local desiredX = forwardX*f + rightX*s
    local desiredZ = forwardZ*f + rightZ*s

    local running = love.keyboard.isDown("lshift", "rshift")
    local moveSpeed = running and 6.0 or 3.5
    local targetVX, targetVZ = desiredX*moveSpeed, desiredZ*moveSpeed
    local control = grounded and 1.0 or airControl
    local rate = (inputLen > 0) and acceleration or groundFriction
    rate = rate * control
    local blend = math.min(1, rate*dt)

    velocityX = velocityX + (targetVX - velocityX) * blend
    velocityZ = velocityZ + (targetVZ - velocityZ) * blend

    local oldX, oldZ = player.x, player.z
    player.x = math.max(-12, math.min(12, player.x + velocityX*dt))
    player.z = math.max(-8, math.min(25, player.z + velocityZ*dt))

    -- Face the actual horizontal movement direction. Camera can rotate while standing still.
    if math.abs(velocityX) + math.abs(velocityZ) > 0.12 then
        local desiredFacing = math.atan2(velocityX, velocityZ)
        local angleDiff = (desiredFacing - facing + math.pi) % (2*math.pi) - math.pi
        facing = facing + angleDiff * math.min(1, 12*dt)
    end

    -- Gravity and jump. Air steering above is weaker than ground steering.
    if not grounded then
        verticalVelocity = verticalVelocity - 18.0*dt
        player.y = player.y + verticalVelocity*dt
        if player.y <= 0 then
            player.y = 0
            verticalVelocity = 0
            grounded = true
        end
    end

    -- Tactical enemy AI state machine:
    -- idle -> chase/surround -> block/dodge -> wind-up -> attack -> recover.
    -- Enemies choose different orbit positions so they don't all stand in one line.
    for _,e in ipairs(enemies) do
        if e.alive then
            e.cooldown = math.max(0, (e.cooldown or 0) - dt)
            e.attackTimer = math.max(0, (e.attackTimer or 0) - dt)
            e.dodgeCooldown = math.max(0, (e.dodgeCooldown or 0) - dt)
            e.blockTimer = math.max(0, (e.blockTimer or 0) - dt)
            e.flash = math.max(0, e.flash - dt)

            local dx, dz = player.x - e.x, player.z - e.z
            local dist = math.sqrt(dx*dx + dz*dz)
            e.facing = math.atan2(dx, dz)
            if e.state == nil then e.state = "idle" end
            if e.aiId == nil then e.aiId = 1 end

            -- If the player begins a sword swing nearby, react defensively.
            if dist < 2.6 and attackTimer > 0 and
               e.state ~= "dodge" and e.state ~= "block" and
               e.state ~= "attack" and e.state ~= "windup" and
               e.dodgeCooldown <= 0 then
                -- One enemy tends to block, others are more likely to dodge.
                if e.aiId % 2 == 0 then
                    e.state = "block"
                    e.blockTimer = 0.42
                else
                    e.state = "dodge"
                    e.attackTimer = 0.32
                    e.dodgeCooldown = 1.8
                    e.dodgeDir = (e.aiId % 3 == 0) and 1 or -1
                end
            end

            if e.state == "idle" then
                if dist < 20 then e.state = "chase" end

            elseif e.state == "chase" then
                if dist > 22 then
                    e.state = "idle"
                elseif dist < 2.0 and e.cooldown <= 0 then
                    e.state = "windup"
                    e.attackTimer = 0.55
                else
                    -- Chase directly at long range. Only orbit once close, preventing
                    -- the enemy from heading toward a distant offset instead of the player.
                    local tx, tz = player.x, player.z
                    local desiredDist = 1.55
                    if dist < 4.0 then
                        local orbitAngle = (e.aiId - 1) * (2 * math.pi / #enemies)
                        tx = player.x + math.sin(orbitAngle) * desiredDist
                        tz = player.z + math.cos(orbitAngle) * desiredDist
                    end
                    local txd, tzd = tx - e.x, tz - e.z
                    local targetDist = math.sqrt(txd*txd + tzd*tzd)
                    if targetDist > 0.15 then
                        local speed = dist < 3.5 and 1.45 or 2.4
                        e.x = e.x + (txd / targetDist) * speed * dt
                        e.z = e.z + (tzd / targetDist) * speed * dt
                    end
                end

            elseif e.state == "dodge" then
                -- Quick lateral/backward step to evade the player's swing.
                local sideX, sideZ = math.cos(e.facing), -math.sin(e.facing)
                e.x = e.x + sideX * (e.dodgeDir or 1) * 4.0 * dt
                e.z = e.z + sideZ * (e.dodgeDir or 1) * 4.0 * dt
                if e.attackTimer <= 0 then e.state = "chase" end

            elseif e.state == "block" then
                -- Blocking reduces damage from the player's swing.
                if e.blockTimer <= 0 then e.state = "chase" end

            elseif e.state == "windup" then
                if e.attackTimer <= 0 then
                    e.state = "attack"
                    e.attackTimer = 0.20
                end

            elseif e.state == "attack" then
                if e.attackTimer <= 0 then
                    local hx, hz = player.x - e.x, player.z - e.z
                    local hd = math.sqrt(hx*hx + hz*hz)
                    local front = hx * math.sin(e.facing or 0) + hz * math.cos(e.facing or 0)
                    if hd < 2.0 and front > -0.2 then
                        player.health = math.max(0, player.health - 8)
                        message, messageTimer = "An enemy hit you! -8 HP", 1.0
                    end
                    e.state = "recover"
                    e.attackTimer = 0.55
                    e.cooldown = 1.0

                end

            elseif e.state == "recover" then
                if e.attackTimer <= 0 then e.state = "chase" end
            end

            e.x = math.max(-13, math.min(13, e.x))
            e.z = math.max(-9, math.min(27, e.z))
        end
    end

    if attackTimer>0 and attackTimer<0.24 then
        for _,e in ipairs(enemies) do
            if e.alive and not e.hitThisSwing then
                local dx,dz=e.x-player.x,e.z-player.z
                local dist=math.sqrt(dx*dx+dz*dz)
                local front=dx*math.sin(facing)+dz*math.cos(facing)
                if dist<2 and front>-0.1 then
                    if e.state == "block" then
                        -- A successful block prevents the hit and briefly staggers the defender.
                        e.blockTimer = 0
                        e.state = "recover"
                        e.attackTimer = 0.28
                        message = "Blocked!"
                        messageTimer = 0.65
                    elseif e.state ~= "dodge" then
                        e.health=e.health-1
                        e.flash=0.18
                        message=e.health<=0 and "Enemy defeated!" or "Hit!"
                        messageTimer=0.8
                        if e.health<=0 then e.alive=false end
                    else
                        message = "Miss! Enemy dodged."
                        messageTimer = 0.65
                    end
                    e.hitThisSwing=true
                end
            end
        end
    end
    if attackTimer==0 then for _,e in ipairs(enemies) do e.hitThisSwing=false end end
end

-- Camera obstruction test against selected large ruin blocks/columns.
-- Samples the line from the player target to the desired camera position.
local function cameraPosition(targetX, targetY, targetZ, desiredX, desiredY, desiredZ)
    local obstacles = {
        {-6.8,0.0,6.2,-5.2,3.9,7.8},
        {-2.8,0.0,6.2,-1.2,3.9,7.8},
        {1.2,0.0,12.2,2.8,4.0,13.8},
        {5.2,0.0,12.2,6.8,4.0,13.8},
        {-3.0,0.0,4.5,-2.7,0.7,11.5},
        {2.7,0.0,8.0,3.0,0.7,16.0}
    }
    local dx,dy,dz=desiredX-targetX,desiredY-targetY,desiredZ-targetZ
    local length=math.sqrt(dx*dx+dy*dy+dz*dz)
    local steps=math.max(1,math.ceil(length/0.18))
    local safeT=1
    for i=1,steps do
        local t=i/steps
        local x,y,z=targetX+dx*t,targetY+dy*t,targetZ+dz*t
        for _,b in ipairs(obstacles) do
            if x>b[1]-0.22 and x<b[4]+0.22
            and y>b[2]-0.22 and y<b[5]+0.22
            and z>b[3]-0.22 and z<b[6]+0.22 then
                safeT=math.max(0.12,(i-1)/steps)
                return targetX+dx*safeT,targetY+dy*safeT,targetZ+dz*safeT
            end
        end
    end
    return desiredX,desiredY,desiredZ
end

function love.draw()
    love.graphics.clear(0.40,0.62,0.80,1,true,1)
    love.graphics.setDepthMode("less",true)
    love.graphics.setShader(shader)

    local w,h=love.graphics.getDimensions()
    shader:send("uProjection","column",perspective(math.rad(68),w/h,0.1,120))

    local targetX,targetY,targetZ=player.x,1.15+(player.y or 0),player.z
    local pitch=cameraPitch
    local fx,fy,fz=math.sin(yaw)*math.cos(pitch),math.sin(pitch),math.cos(yaw)*math.cos(pitch)
    local desiredX,desiredY,desiredZ =
        targetX-fx*cameraDistance,
        targetY-fy*cameraDistance+0.35,
        targetZ-fz*cameraDistance

    local wantedX,wantedY,wantedZ = cameraPosition(
        targetX,targetY,targetZ,desiredX,desiredY,desiredZ)

    if not cameraX then
        cameraX,cameraY,cameraZ=wantedX,wantedY,wantedZ
    else
        local followBlend=math.min(1,cameraSmooth*love.timer.getDelta())
        cameraX=cameraX+(wantedX-cameraX)*followBlend
        cameraY=cameraY+(wantedY-cameraY)*followBlend
        cameraZ=cameraZ+(wantedZ-cameraZ)*followBlend
    end
    shader:send("uView","column",viewMatrix(cameraX,cameraY,cameraZ,yaw,pitch))

    -- Broad grassy terrain, raised borders and a tiled ceremonial walkway.
    drawBox(0,-0.22,9,80,0.35,90,0,{0.22,0.32,0.20})
    drawBox(-2.25,-0.015,9,0.32,0.10,46,0,{0.34,0.33,0.29})
    drawBox( 2.25,-0.015,9,0.32,0.10,46,0,{0.34,0.33,0.29})
    for z=0,26,1.65 do
        drawBox(0,0.015,z,4.15,0.09,1.52,0,{0.48,0.44,0.36})
        drawBox(-1.02,0.067,z,1.85,0.025,0.035,0,{0.62,0.58,0.48})
        drawBox(1.02,0.067,z,1.85,0.025,0.035,0,{0.36,0.34,0.29})
        if z%3.3 < 0.2 then
            drawBox(-1.55,0.08,z+0.20,0.18,0.035,0.18,0,{0.70,0.66,0.55})
            drawBox(1.55,0.08,z-0.20,0.18,0.035,0.18,0,{0.70,0.66,0.55})
        end
    end
    -- Low retaining walls and broken stone debris.
    drawBox(-3.1,0.22,8,0.35,0.44,7,0,{0.48,0.45,0.38})
    drawBox(3.1,0.22,12,0.35,0.44,8,0,{0.48,0.45,0.38})
    drawBox(-7,0.38,4,2.0,0.76,1.6,0.12,{0.35,0.34,0.30})
    drawBox(7,0.45,5,1.8,0.90,1.5,-0.10,{0.40,0.38,0.33})
    drawBox(-8,0.70,12,1.8,1.4,1.7,0.15,{0.36,0.35,0.31})
    drawBox(8,0.75,14,2.0,1.5,1.8,-0.12,{0.36,0.35,0.31})
    -- Two detailed colonnades and a shrine at the end of the path.
    drawArch(-4,7)
    drawArch(4,13)
    drawShrine()
    drawGrassAndPlants()

    for _,e in ipairs(enemies) do if e.alive then drawEnemy(e) end end
    drawHero()

    love.graphics.setShader()
    love.graphics.setDepthMode()
    love.graphics.setColor(1,1,1,1)
    love.graphics.print("W/S Move | A/D Camera | J/L Strafe | SPACE Jump | K Sword | SHIFT Run",10,10)
    love.graphics.print("HP: "..player.health.."  | GPU 3D | Detailed low-poly world",10,30)
    local chasing = 0
    for _,e in ipairs(enemies) do
        if e.alive and e.state ~= "idle" then chasing = chasing + 1 end
    end
    love.graphics.print("Active enemies: "..chasing.."/"..#enemies,10,50)
    if messageTimer>0 then love.graphics.print(message,10,SH-28) end
end
