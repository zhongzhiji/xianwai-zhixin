const assert=require('node:assert/strict');
const {RhythmSession}=require('./rhythm-core.js');
let count=0;
function test(name,fn){fn();console.log('PASS',name);count++}
const events=[{note:60,length:4},{note:62,length:4},{note:60,length:4}];
test('accurate input gives exact first score, combo and best',()=>{
 const s=new RhythmSession(events,{bpm:120});assert.equal(s.hit(0,3).grade,'perfect');assert.equal(s.score,100);
 assert.equal(s.hit(1,3.6).grade,'good');assert.equal(s.score,162);assert.equal(s.combo,2);assert.equal(s.best,2);
});
test('wrong lane and late notes do not score',()=>{
 const s=new RhythmSession(events);assert.equal(s.hit(1,3).grade,'wrong');assert.equal(s.score,0);
 s.tick(3.146);assert.equal(s.counts.miss,1);s.tick(3.2);assert.equal(s.counts.miss,1);
});
test('a note can be judged only once',()=>{const s=new RhythmSession(events);s.hit(0,3);s.hit(0,3.01);assert.equal(s.score,100);assert.equal(s.counts.perfect,1)});
test('early input outside window cannot pre-hit',()=>{const s=new RhythmSession(events);s.hit(0,2.8);assert.equal(s.score,0);assert.equal(s.notes[0].state,'waiting')});
test('automatic has expressive timing and velocity but never human stats',()=>{
 const s=new RhythmSession(events,{automatic:true});assert.equal(s.hit(0,3),null);const e=s.tick(20);
 assert.equal(e.length,3);assert(e.every(x=>x.grade==='demo'));assert.equal(s.score,0);assert.equal(s.combo,0);
 assert.deepEqual(s.counts,{perfect:0,good:0,miss:0});assert(s.notes.some(n=>n.offset!==0));assert(new Set(s.notes.map(n=>n.velocity)).size>1);
});
test('miss breaks combo; rest never counts as miss',()=>{
 const s=new RhythmSession([...events,{note:0,length:4}],{bpm:120});s.hit(0,3);s.tick(20);
 assert.equal(s.combo,0);assert.equal(s.best,1);assert.equal(s.counts.miss,2);
});
test('tempo and durations determine note positions',()=>{
 const s=new RhythmSession([{note:60,length:2},{note:62,length:8}],{bpm:60});assert.equal(s.notes[1].time,3.5);assert.equal(s.end,7.5);
});
console.log('TOTAL',count,'PASS');
