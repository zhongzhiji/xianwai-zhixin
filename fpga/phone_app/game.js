/* Browser demonstration and real browser-input practice. No fabricated hardware ACK. */
(() => {
  const q=s=>document.querySelector(s), pitch=window.rhythmPitches;
  const keyCodes=['KeyA','KeyS','KeyD','KeyF','KeyJ','KeyK','KeyL','Semicolon'];
  const names=['C4','D4','E4','F4','G4','A4','B4','C5'];
  const colors=['#64ebd1','#65e0e9','#69c9ff','#9aa8ff','#bda1ff','#e8a1e8','#ffc48a','#f2df8b'];
  let ac, master, analyser, muted=false, lastPitch=60, session=null, start=0, running=false;
  let starting=false, revision=0, polyTimer=null, voices=[], latest='', feedbackAt=0;
  const live=new Map(), inputs=new Map(), autoReleases=[], flashes=Array(8).fill(-10);
  let frame=0;
  async function audio(){
    if(!ac){ac=new AudioContext();master=ac.createGain();master.gain.value=.28;
      const limiter=ac.createDynamicsCompressor();limiter.threshold.value=-15;limiter.ratio.value=10;
      analyser=ac.createAnalyser();analyser.fftSize=512;master.connect(limiter);limiter.connect(analyser);analyser.connect(ac.destination);}
    if(ac.state==='suspended')await ac.resume();return ac;
  }
  function voice(midi,velocity=96,duration=null,normalize=1){
    if(!ac)return null;
    const now=ac.currentTime,osc=ac.createOscillator(),gain=ac.createGain();
    const kind=q('#timbre').value,glide=+q('#glide').value/1000;
    osc.type={keys:'triangle',pluck:'triangle',wind:'sine',synth:'sawtooth'}[kind];
    const frequency=n=>440*Math.pow(2,(n-69)/12);
    osc.frequency.setValueAtTime(frequency(glide?lastPitch:midi),now);
    if(glide)osc.frequency.exponentialRampToValueAtTime(frequency(midi),now+glide);
    lastPitch=midi;
    const lfo=ac.createOscillator(),depth=ac.createGain();lfo.frequency.value=5.2;
    depth.gain.value=+q('#vibrato').value;lfo.connect(depth);depth.connect(osc.detune);
    const amplitude=(velocity/127)*normalize;
    gain.gain.setValueAtTime(0,now);gain.gain.linearRampToValueAtTime(amplitude,now+(kind==='wind'?.045:.008));
    gain.gain.exponentialRampToValueAtTime(Math.max(.001,amplitude*(kind==='pluck'?.12:.52)),now+(kind==='pluck'?.22:.35));
    osc.connect(gain);gain.connect(master);osc.start(now);lfo.start(now);
    let ended=false;const v={released:false,release(){if(ended)return;ended=true;v.released=true;const t=ac.currentTime;
      gain.gain.cancelAndHoldAtTime(t);gain.gain.linearRampToValueAtTime(0,t+.12);osc.stop(t+.14);lfo.stop(t+.14);},depth};
    osc.onended=()=>{osc.disconnect();lfo.disconnect();depth.disconnect();gain.disconnect();voices=voices.filter(x=>x!==v)};
    voices.push(v);
    if(duration!==null)autoReleases.push({time:performance.now()/1000+duration,release:()=>v.release()});
    return v;
  }
  async function previewOn(n,v){
    // A release during AudioContext.resume must not resurrect a stale note.
    const marker={};live.get(n)?.voice?.release();live.set(n,marker);
    await audio();if(live.get(n)!==marker)return;
    marker.voice=voice(n,v);
  }
  function previewOff(n){live.get(n)?.voice?.release();live.delete(n)}
  function silence(){for(const v of voices)v.release();live.clear();autoReleases.length=0;inputs.clear();
    document.querySelectorAll('#game-keys .on').forEach(b=>b.classList.remove('on'));
    clearTimeout(polyTimer);document.querySelectorAll('[data-voices]').forEach(b=>b.classList.remove('active'));
    q('#voice-info').textContent='试听已停止。';}
  window.previewOn=previewOn;window.previewOff=previewOff;window.stopPreviewNotes=silence;
  function elapsed(){return performance.now()/1000-start}
  function setFeedback(text,sub=''){q('#game-feedback').replaceChildren(document.createTextNode(text));
    const small=document.createElement('small');small.textContent=sub;q('#game-feedback').append(small);feedbackAt=performance.now();}
  function judgment(result){if(!result)return;
    const labels={perfect:'PERFECT',good:'GOOD',miss:'MISS',wrong:'错音',demo:'自动演奏'};
    if(result.grade==='demo'){
      const n=result.note;voice(n.midi,n.velocity,n.duration*(.91+.08*Math.sin(n.id)));
      const key=q(`#game-keys [data-lane="${n.lane}"]`);key?.classList.add('on');
      autoReleases.push({time:performance.now()/1000+n.duration*.87,release:()=>key?.classList.remove('on')});
      flashes[n.lane]=performance.now()/1000;
      setFeedback('自动演奏',`${names[n.lane]||n.midi}  ·  力度 ${n.velocity}  ·  自然时差 ${Math.round(result.offset)} ms`);
    }else{
      if(result.grade!=='miss'&&result.grade!=='wrong')flashes[result.lane]=performance.now()/1000;
      const sub=result.offset==null?'继续跟随节拍':`${result.offset>=0?'晚':'早'} ${Math.abs(Math.round(result.offset))} ms`;
      setFeedback(labels[result.grade],sub);
    }
    updateStats();
  }
  function updateStats(){if(!session)return;
    q('#game-score').textContent=session.automatic?'—':String(session.score).padStart(5,'0');
    q('#game-combo').textContent=session.automatic?'—':session.combo;
    const {perfect,good,miss}=session.counts,total=perfect+good+miss;
    q('#game-accuracy').textContent=session.automatic?'演示':total?Math.round((perfect+good)/total*100)+'%':'—';
  }
  function stop(reset=false){revision++;starting=false;running=false;silence();
    held.clear();document.querySelectorAll('#keys .on').forEach(b=>b.classList.remove('on'));
    command('/api/panic',{}).then(display).catch(e=>q('#status').textContent=e.message);
    q('#song').disabled=false;q('#bpm').disabled=false;
    if(reset){session=null;q('#session-mode').textContent='等待开始';q('#game-summary').hidden=true;
      q('#game-score').textContent='0';q('#game-combo').textContent='0';q('#game-accuracy').textContent='—';q('#game-time').textContent='0:00';q('#game-progress').style.width='0%';
      setFeedback('跟随光轨 · 按下琴键','ASDF JKL; / 鼠标 / 多点触摸');}
  }
  async function begin(automatic){
    if(starting||busy)return;stop();starting=true;const own=revision;
    try{await audio();if(own!==revision)return;
      const phrase=songs[q('#song').value];
      // Four phrases in the automatic demonstration; timing and velocity are deterministic.
      const notes=automatic?Array.from({length:4},()=>phrase).flat():phrase;
      session=new RhythmSession(notes.map(note=>({note,length:4})),{bpm:+q('#bpm').value,automatic});
      start=performance.now()/1000;running=true;
      q('#session-mode').textContent=automatic?'自动演奏 · 不计分':'真人练习 · 网页输入';
      q('#game-hint').textContent=automatic?'自动演示使用独立音符、自然力度、微小时差和释音；声音来自浏览器，未向 FPGA 发送自动按键。':'真人练习：按下琴键可得分，并经网关发送音符；浏览器判定与 FPGA 实物验证分开记录。长音尾部提示持续时值，当前成绩判定起音。';
      q('#game-summary').hidden=true;q('#song').disabled=true;q('#bpm').disabled=true;
      updateStats();setFeedback('准备','3 秒后开始');
    }catch(e){q('#status').textContent=e.message}finally{starting=false}
  }
  function press(lane,id){
    if(busy||inputs.has(id)||(running&&session?.automatic))return;
    const n=pitch[lane];if(held.has(n))return;
    inputs.set(id,lane);held.add(n);q(`#game-keys [data-lane="${lane}"]`).classList.add('on');
    previewOn(n,+q('#velocity').value);note(n,+q('#velocity').value);
    flashes[lane]=performance.now()/1000;
    if(running)judgment(session.hit(lane,elapsed()));
  }
  function release(id){if(!inputs.has(id))return;const lane=inputs.get(id),n=pitch[lane];inputs.delete(id);
    q(`#game-keys [data-lane="${lane}"]`).classList.remove('on');previewOff(n);
    if(held.delete(n))note(n,0);
  }
  pitch.forEach((n,i)=>{const b=document.createElement('button');b.dataset.lane=i;b.setAttribute('aria-label',`音游 ${names[i]} ${keyCodes[i]}`);
    b.innerHTML=names[i]+`<span>${['A','S','D','F','J','K','L',';'][i]}</span>`;
    b.onpointerdown=e=>{e.preventDefault();b.setPointerCapture(e.pointerId);press(i,'pointer'+e.pointerId)};
    b.onpointerup=b.onpointercancel=b.onlostpointercapture=e=>release('pointer'+e.pointerId);
    q('#game-keys').append(b);
  });
  document.addEventListener('keydown',e=>{const lane=keyCodes.indexOf(e.code);
    if(lane<0||e.repeat||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName))return;
    e.preventDefault();press(lane,e.code);
  });
  document.addEventListener('keyup',e=>release(e.code));
  window.addEventListener('blur',()=>{if(running){stop();setFeedback('演奏已停止','窗口失去焦点，已尝试释音；点击开始重新演奏')}});
  document.addEventListener('visibilitychange',()=>{if(document.hidden){stop();setFeedback('演奏已停止','页面离开后不继续累计判定')}});
  q('#game-start').onclick=()=>begin(false);q('#game-demo').onclick=()=>begin(true);q('#game-stop').onclick=()=>stop(true);
  q('#local-audio').onclick=async()=>{await audio();muted=!muted;master.gain.setTargetAtTime(muted?0:.28,ac.currentTime,.02);q('#local-audio').textContent='浏览器试听：'+(muted?'关':'开')};
  q('#recording').onclick=()=>{document.body.classList.toggle('recording');q('#recording').textContent=document.body.classList.contains('recording')?'退出拍摄视图':'拍摄视图'};
  for(const [id,suffix] of [['velocity',''],['glide',' ms'],['vibrato',' ct']])q('#'+id).addEventListener('input',()=>{
    q('#'+id+'-value').textContent=q('#'+id).value+suffix;
    if(id==='vibrato'&&ac)for(const v of voices)v.depth.gain.setTargetAtTime(+q('#vibrato').value,ac.currentTime,.03);
  });
  document.querySelectorAll('[data-voices]').forEach(b=>b.onclick=async()=>{
    stop(true);const own=revision;await audio();if(own!==revision)return;
    const count=+b.dataset.voices;for(let i=0;i<count;i++)voice(48+i,96,3,1/Math.sqrt(count));
    b.classList.add('active');q('#voice-info').textContent=`浏览器实时合成：${count} 个独立振荡器及包络；不是 FPGA 实测。`;
    polyTimer=setTimeout(()=>{b.classList.remove('active');q('#voice-info').textContent=`${count} 声部试听完成。FPGA 32 声部请拍摄第 18 段。`},3300);
  });
  async function ports(){try{const j=await api('/api/ports');const select=q('#port'),previous=select.value;select.replaceChildren();
    for(const p of j.ports){const o=document.createElement('option');o.value=p.device;o.textContent=p.device+' · '+p.description;select.append(o)}
    if(!j.ports.length){const o=document.createElement('option');o.value='';o.textContent='未发现 COM 口';select.append(o)}
    else if(j.ports.some(p=>p.device===previous))select.value=previous;
  }catch(e){q('#connection-detail').textContent=e.message}}
  q('#ports-refresh').onclick=ports;
  async function changeConnection(path,data){stop(true);q('#connect').disabled=q('#disconnect').disabled=true;
    try{const j=await command(path,data);display(j);q('#connection-detail').textContent=j.message}
    catch(e){q('#connection-detail').textContent=e.message}
    finally{q('#connect').disabled=q('#disconnect').disabled=false}}
  q('#connect').onclick=()=>changeConnection('/api/connect',{port:q('#port').value,baud:+q('#baud').value});
  q('#disconnect').onclick=()=>changeConnection('/api/disconnect',{});ports();
  // Imports and emergency release stop the current performance before queueing new data.
  q('#send').addEventListener('click',()=>stop(true),true);
  q('#file').addEventListener('change',()=>stop(true),true);
  q('#panic').addEventListener('click',()=>{running=false;silence();q('#song').disabled=false;q('#bpm').disabled=false},true);
  const canvas=q('#game-canvas'),ctx=canvas.getContext('2d'),scope=q('#audio-scope'),sx=scope.getContext('2d');
  function fit(c){const r=c.getBoundingClientRect(),dpr=Math.min(2,devicePixelRatio||1);
    const w=Math.round(r.width*dpr),h=Math.round(r.height*dpr);if(c.width!==w||c.height!==h){c.width=w;c.height=h}return [r.width,r.height,dpr]}
  function draw(){frame++;const now=performance.now()/1000;
    for(let i=autoReleases.length-1;i>=0;i--)if(now>=autoReleases[i].time){autoReleases[i].release();autoReleases.splice(i,1)}
    let time=session?elapsed():0;
    if(running){for(const e of session.tick(time))judgment(e);
      if(time<3)setFeedback(String(Math.ceil(3-time)),'准备 · 跟随节拍');
      if(time>=session.end){const completed=session;stop();q('#session-mode').textContent=completed.automatic?'自动演奏结束':'练习结束';
        q('#game-summary').hidden=false;q('#game-summary').textContent=completed.automatic?'自动演示完成。以上为浏览器合成与动画，不生成真人成绩。':
          `本次网页输入：${completed.score} 分 · 最佳连击 ${completed.best} · PERFECT ${completed.counts.perfect} / GOOD ${completed.counts.good} / MISS ${completed.counts.miss} · 错音 ${completed.errors}`;
        setFeedback('演奏结束',completed.automatic?'自动演示 · 不计分':'再次练习，找到更稳的节拍');}
      q('#game-time').textContent=Math.floor(Math.max(0,time-3)/60)+':'+String(Math.floor(Math.max(0,time-3)%60)).padStart(2,'0');
      q('#game-progress').style.width=Math.min(100,Math.max(0,(time-3)/(session.end-5)*100))+'%';
    }
    const [w,h,d]=fit(canvas);ctx.setTransform(d,0,0,d,0,0);ctx.clearRect(0,0,w,h);
    const laneW=w/8,line=h-64,travel=line-25;
    const gradient=ctx.createLinearGradient(0,0,0,h);gradient.addColorStop(0,'#101b30');gradient.addColorStop(1,'#080f1e');ctx.fillStyle=gradient;ctx.fillRect(0,0,w,h);
    for(let i=0;i<8;i++){
      ctx.fillStyle=i%2?'#ffffff04':'#ffffff01';ctx.fillRect(i*laneW,0,laneW,h);
      ctx.strokeStyle='#2e40584f';ctx.beginPath();ctx.moveTo(i*laneW,0);ctx.lineTo(i*laneW,h);ctx.stroke();
      const age=now-flashes[i];if(age<.38){ctx.globalAlpha=Math.max(0,1-age/.38)*.32;
        ctx.fillStyle=colors[i];ctx.fillRect(i*laneW,line-85,laneW,h-line+85);ctx.globalAlpha=1;}
      ctx.fillStyle='#94aac2';ctx.font='11px Consolas';ctx.textAlign='center';ctx.fillText(names[i],i*laneW+laneW/2,h-22);
    }
    if(session&&running){
      const beat=60/(+q('#bpm').value);ctx.strokeStyle='#3c50683b';
      for(let b=Math.floor((time-3)/beat);b<(time-3)/beat+5;b++){const y=line-(3+b*beat-time)/2.4*travel;if(y>0&&y<h){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()}}
      for(const n of session.notes){if(n.lane<0||!['waiting','miss'].includes(n.state))continue;
        const y=line-(n.time-time)/2.4*travel,tail=n.duration/2.4*travel;
        if(y< -20||y-tail>h+20)continue;
        const x=n.lane*laneW+Math.max(5,laneW*.14),nw=laneW-Math.max(10,laneW*.28);
        ctx.fillStyle=colors[n.lane];ctx.globalAlpha=n.state==='miss'?.12:.24;ctx.fillRect(x+nw*.32,y-tail,nw*.36,tail);
        ctx.globalAlpha=n.state==='miss'?.25:1;ctx.shadowBlur=12;ctx.shadowColor=colors[n.lane];
        ctx.beginPath();ctx.roundRect(x,y-8,nw,14,4);ctx.fill();ctx.shadowBlur=0;ctx.globalAlpha=1;
      }
    }else if(!session){ctx.fillStyle='#8098b5';ctx.font='13px Microsoft YaHei';ctx.textAlign='center';ctx.fillText('选择真人练习，或播放自然演奏演示',w/2,h*.55)}
    ctx.shadowColor='#65ebd4';ctx.shadowBlur=14;ctx.strokeStyle='#84f7e2';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(0,line);ctx.lineTo(w,line);ctx.stroke();ctx.shadowBlur=0;ctx.lineWidth=1;
    if(frame%2===0){const [sw,sh,sd]=fit(scope);sx.setTransform(sd,0,0,sd,0,0);sx.clearRect(0,0,sw,sh);sx.strokeStyle='#64e6d3';sx.beginPath();
      const data=new Uint8Array(256);if(analyser)analyser.getByteTimeDomainData(data);else data.fill(128);
      data.forEach((v,i)=>{const x=i/255*sw,y=sh/2+(v-128)/128*sh*.46;i?sx.lineTo(x,y):sx.moveTo(x,y)});sx.stroke();}
    q('#game-feedback').style.opacity=running&&time>3&&performance.now()-feedbackAt>850?'.3':'1';requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
  // Read-only test/diagnostic snapshot: no route can submit or synthesize a human score.
  window.rhythmSnapshot=()=>({running,automatic:session?.automatic,score:session?.score||0,counts:session?.counts,
    notes:session?.notes.map(n=>({time:n.time,lane:n.lane,state:n.state})),elapsed:session?elapsed():0,voices:voices.filter(v=>!v.released).length});
})();
