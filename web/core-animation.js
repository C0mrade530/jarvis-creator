const canvas=$('field'),ctx=canvas.getContext('2d');
const tickPaths=role==='core'?buildTickPaths():[];
let w=0,h=0,dpr=1,lastCoreFrame=-Infinity;
function resize(){
  w=innerWidth;h=innerHeight;
  dpr=Math.min(devicePixelRatio||1,role==='core'?1.25:1);
  canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);
  ctx.setTransform(dpr,0,0,dpr,0,0);
  if(role!=='core')paintField(0,state.phase!=='idle');
}
function strokeArc(x,y,r,a,b,colour,width=1){ctx.strokeStyle=colour;ctx.lineWidth=width;ctx.beginPath();ctx.arc(x,y,r,a,b);ctx.stroke();}
function paintField(t,active){
  ctx.clearRect(0,0,w,h);
  // A sparse instrument field, never a simulated screenshot.
  for(let i=0;i<42;i++){
    const x=(Math.sin(i*57.31)*.5+.5)*w,y=(Math.cos(i*37.17)*.5+.5)*h;
    ctx.fillStyle=`rgba(118,213,245,${(.08+.08*Math.sin(t+i))*(active?1:.5)})`;ctx.fillRect(x,y,1,1);
  }
  ctx.strokeStyle='#17303b';ctx.lineWidth=1;
  for(const [x,y,sx,sy] of [[18,18,1,1],[w-18,18,-1,1],[18,h-18,1,-1],[w-18,h-18,-1,-1]]){ctx.beginPath();ctx.moveTo(x+23*sx,y);ctx.lineTo(x,y);ctx.lineTo(x,y+23*sy);ctx.stroke();}
}
function animateCore(now){
  requestAnimationFrame(animateCore);
  if(now-lastCoreFrame<32)return;
  lastCoreFrame=now;
  const t=reduced?0:now*.001, active=state.phase!=='idle';
  smoothLevel+=(clamp(state.level||0)-smoothLevel)*.39;
  paintField(t,active);
  drawCore(t,active);
  for(let i=0;i<bars.length;i++){
    const height=3+smoothLevel*(10+15*Math.sin(i*.75+t*18)**2)*(1-Math.abs(i-27)/35);
    const value=`${Math.round(height*10)/10}px`;
    if(bars[i].style.height!==value)bars[i].style.height=value;
  }
}
function buildTickPaths(){
  const paths=[
    {path:new Path2D(),color:'#ffd198',width:1.2},
    {path:new Path2D(),color:'#ffd198',width:.6},
    {path:new Path2D(),color:'#63bed6',width:1.2},
    {path:new Path2D(),color:'#24576a',width:.6}
  ];
  for(let i=0;i<240;i++){
    const angle=i*Math.PI/120, major=i%10===0;
    const x=Math.cos(angle), y=Math.sin(angle), inner=major?1.23:1.26;
    const {path}=paths[(i%60<3?0:2)+(major?0:1)];
    path.moveTo(x*inner,y*inner);
    path.lineTo(x*1.28,y*1.28);
  }
  return paths;
}

function addMeshSegment(paths,previous,point){
  const path=paths[point[2]>0?1:0];
  path.moveTo(previous[0],previous[1]);
  path.lineTo(point[0],point[1]);
}

function drawCore(t,active){
  const x=w*.5,y=h*.46,base=Math.min(w*.24,h*(h<760?.205:.235)),energy=smoothLevel;
  const boot=active?ease(state.elapsed/1.5):.8;
  const r=base*(1+energy*.045),rotation=t*(active?.17:.055);
  ctx.save();ctx.translate(x,y);ctx.scale(boot,boot);
  const glow=ctx.createRadialGradient(0,0,r*.15,0,0,r*1.6);glow.addColorStop(0,`rgba(58,201,247,${active?.09+energy*.09:.035})`);glow.addColorStop(.6,'rgba(35,161,216,.025)');glow.addColorStop(1,'transparent');ctx.fillStyle=glow;ctx.fillRect(-r*2,-r*2,r*4,r*4);
  // Reuse the calibrated tick paths. The radius changes with the voice, so
  // scale their coordinates while keeping the original line widths.
  ctx.save();ctx.scale(r,r);
  for(const {path,color,width} of tickPaths){
    ctx.strokeStyle=color;ctx.lineWidth=width/r;ctx.stroke(path);
  }
  ctx.restore();
  strokeArc(0,0,r*1.32,0,Math.PI*2,'#163642',.7);
  strokeArc(0,0,r*1.18,rotation,rotation+Math.PI*1.4,'#2a8aa8',1);
  strokeArc(0,0,r*1.18,rotation+Math.PI*1.5,rotation+Math.PI*1.92,'#99eeff',2.2);
  for(let i=0;i<8;i++){const a=i*Math.PI/4-rotation*.7;strokeArc(0,0,r*1.1,a,a+.54,i%3===0?'#83eaff':'#224c60',i%3===0?3:1);}
  strokeArc(0,0,r*1.04,0,Math.PI*2,'#3c8ca6',.5);
  for(let i=0;i<4;i++){
    const a=i*Math.PI/2+rotation*.3;strokeArc(0,0,r*.98,a,a+.85,'#4ebbd9',1.5);strokeArc(0,0,r*.91,a+.1,a+.75,'#1a4d67',1);
  }
  // Project a rotating latitude/longitude mesh into screen space.
  const yaw=rotation*.8,tilt=.32+Math.sin(t*.12)*.12,sphere=r*.8;
  const sinTilt=Math.sin(tilt), cosTilt=Math.cos(tilt);
  const project=(lat,lon)=>{
    const flat=Math.cos(lat);
    const px=flat*Math.cos(lon+yaw),pz=flat*Math.sin(lon+yaw),py=Math.sin(lat);
    return [px*sphere,(py*cosTilt-pz*sinTilt)*sphere,py*sinTilt+pz*cosTilt];
  };
  // Batch the mesh into two depth layers per axis instead of stroking each
  // segment separately. Geometry and front/back opacities are preserved.
  const latitude=[new Path2D(),new Path2D()];
  const longitude=[new Path2D(),new Path2D()];
  for(let j=-6;j<=6;j++){
    const lat=j*Math.PI/16;let prev=null;
    for(let i=0;i<=96;i++){
      const p=project(lat,i*Math.PI/48);
      if(prev)addMeshSegment(latitude,prev,p);
      prev=p;
    }
  }
  ctx.lineWidth=.65;
  ctx.strokeStyle='rgba(110,225,255,.055)';ctx.stroke(latitude[0]);
  ctx.strokeStyle=`rgba(110,225,255,${.24+energy*.2})`;ctx.stroke(latitude[1]);
  ctx.fillStyle=`rgba(178,242,255,${.35+energy*.6})`;
  for(let j=0;j<24;j++){
    let prev=null;for(let i=0;i<=48;i++){
      const p=project(-Math.PI/2+i*Math.PI/48,j*Math.PI/12);
      if(prev)addMeshSegment(longitude,prev,p);
      prev=p;
      if(i%4===0&&p[2]>.2)ctx.fillRect(p[0]-1,p[1]-1,1.6,1.6);
    }
  }
  ctx.strokeStyle='rgba(96,214,248,.05)';ctx.stroke(longitude[0]);
  ctx.strokeStyle=`rgba(96,214,248,${.25+energy*.13})`;ctx.stroke(longitude[1]);
  // Elliptical orbit planes provide spatial depth around the nucleus.
  for(let i=0;i<3;i++){
    ctx.save();ctx.rotate(i*1.07+rotation*.17);ctx.strokeStyle=i===1?'#ffbf7666':'#5cdcff66';ctx.lineWidth=.8;ctx.beginPath();ctx.ellipse(0,0,r*.97,r*.32,0,0,Math.PI*2);ctx.stroke();
    const a=t*.5+i*2;ctx.fillStyle=i===1?'#ffd49c':'#d1f7ff';ctx.shadowColor=ctx.fillStyle;ctx.shadowBlur=9;ctx.beginPath();ctx.arc(Math.cos(a)*r*.97,Math.sin(a)*r*.32,2.2,0,Math.PI*2);ctx.fill();ctx.restore();
  }
  // Voice amplitude emits expanding holographic rings and lights orbiting signal points.
  if(active&&energy>.03){
    for(let k=0;k<3;k++){
      const wave=(t*.45+k/3)%1,rr=r*(.75+wave*.75);
      strokeArc(0,0,rr,-rotation+k*2.1,-rotation+k*2.1+Math.PI*1.35,`rgba(126,233,255,${(1-wave)*energy*.28})`,.65);
    }
    for(let k=0;k<18;k++){
      const a=k*Math.PI/9+rotation*2.7,rr=r*(.89+.035*Math.sin(t*4+k));
      ctx.fillStyle=`rgba(169,243,255,${energy*(.3+.4*Math.sin(t*4+k)**2)})`;ctx.fillRect(Math.cos(a)*rr-1,Math.sin(a)*rr-1,2,2);
    }
  }
  const nucleus=ctx.createRadialGradient(0,0,1,0,0,r*.25);nucleus.addColorStop(0,'#d3fcff');nucleus.addColorStop(.05,'#8fefff');nucleus.addColorStop(.18,`rgba(77,214,255,${.15+energy*.3})`);nucleus.addColorStop(1,'transparent');ctx.fillStyle=nucleus;ctx.fillRect(-r*.25,-r*.25,r*.5,r*.5);
  // Audio-reactive contour: grows with actual narration amplitude, not random playback state.
  ctx.strokeStyle=`rgba(140,238,255,${.35+energy*.4})`;ctx.lineWidth=1.2;ctx.beginPath();
  for(let i=0;i<=360;i++){const a=i*Math.PI/180,rr=r*(.88+energy*.045*Math.sin(a*36+t*8));const px=Math.cos(a)*rr,py=Math.sin(a)*rr;i?ctx.lineTo(px,py):ctx.moveTo(px,py);}ctx.closePath();ctx.stroke();
  ctx.font=`${Math.max(7,r*.038)}px Menlo, monospace`;ctx.fillStyle='#66a4b9';ctx.textAlign='center';
  for(let i=0;i<4;i++){const a=i*Math.PI/2;ctx.fillText(['090','180','270','000'][i],Math.cos(a)*r*1.41,Math.sin(a)*r*1.41+3);}
  ctx.restore();
  const cy=y+base*.3;ctx.strokeStyle='#244858';ctx.lineWidth=.6;
  for(const side of [-1,1]){ctx.beginPath();ctx.moveTo(x+side*base*1.34,cy);ctx.lineTo(x+side*base*1.6,cy);ctx.lineTo(x+side*base*1.8,cy-25);ctx.lineTo(x+side*(w*.4),cy-25);ctx.stroke();}
}
addEventListener('resize', resize);
resize();
if (role === 'core') requestAnimationFrame(animateCore);
