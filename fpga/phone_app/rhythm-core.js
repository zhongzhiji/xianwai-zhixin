/* One timeline for notes, input and judgment. Automatic demonstrations never score. */
(function(root){
  const pitches=[60,62,64,65,67,69,71,72];
  class RhythmSession {
    constructor(events,{bpm=112,automatic=false}={}) {
      this.automatic=automatic;this.score=0;this.combo=0;this.best=0;
      this.counts={perfect:0,good:0,miss:0};this.errors=0;this.offsets=[];
      let cursor=3;
      this.notes=events.map((e,i)=>{
        const beats=(e.length||4)/4, duration=beats*60/bpm;
        const note={id:i,midi:e.note,lane:pitches.indexOf(e.note),time:cursor,
          duration:Math.max(.12,duration*.79),state:e.note===0?'rest':'waiting',
          // Deterministic phrasing: accents, small timing variation, no random score.
          offset:Math.sin(i*2.31)*.021+Math.sin(i*.61)*.009,
          velocity:Math.round(83+13*Math.cos(i*.47)+(i%4===0?12:0))};
        cursor+=duration;return note;
      });
      this.end=cursor+2;
    }
    hit(lane,time){
      if(this.automatic)return null;
      const n=this.notes.filter(n=>n.state==='waiting'&&n.lane===lane&&Math.abs(n.time-time)<=.145)
        .sort((a,b)=>Math.abs(a.time-time)-Math.abs(b.time-time))[0];
      if(!n){this.combo=0;this.errors++;return {grade:'wrong',offset:null,lane};}
      const offset=time-n.time, grade=Math.abs(offset)<=.055?'perfect':'good';
      n.state=grade;this.counts[grade]++;this.offsets.push(offset*1000);
      this.score+=(grade==='perfect'?100:60)+Math.min(this.combo,50)*2;
      this.combo++;this.best=Math.max(this.combo,this.best);
      return {grade,offset:offset*1000,lane,note:n};
    }
    tick(time){
      const events=[];
      for(const n of this.notes){
        if(n.state!=='waiting')continue;
        if(this.automatic&&time>=n.time+n.offset){
          n.state='demo';events.push({grade:'demo',offset:n.offset*1000,lane:n.lane,note:n});
        }else if(!this.automatic&&time>n.time+.145){
          n.state='miss';this.combo=0;this.counts.miss++;events.push({grade:'miss',lane:n.lane,note:n});
        }
      }
      return events;
    }
  }
  root.RhythmSession=RhythmSession;root.rhythmPitches=pitches;
  if(typeof module!=='undefined')module.exports={RhythmSession,pitches};
})(typeof window!=='undefined'?window:globalThis);
