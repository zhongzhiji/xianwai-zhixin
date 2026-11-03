"""Run real Icarus processes with exit codes, timeouts and saved raw output."""
from pathlib import Path
import subprocess,re,json,time,sys,shutil,os
ROOT=Path(__file__).resolve().parents[1]; P=ROOT/'fpga'
IV=os.environ.get('IVERILOG') or shutil.which('iverilog') or 'C:/iverilog/bin/iverilog.exe'
VVP=os.environ.get('VVP') or shutil.which('vvp') or str(Path(IV).with_name('vvp.exe'))
OUT=ROOT/'test-results/rtl';OUT.mkdir(parents=True,exist_ok=True)
(P/'sim/out').mkdir(parents=True,exist_ok=True)
shell=(P/'sim/run_all_sim.sh').read_text(encoding='utf-8-sig')
tests=re.search(r'TBS="(.*?)"',shell,re.S).group(1).replace('\\','').split()
if 'tb_uart_jdy9600' not in tests:tests.append('tb_uart_jdy9600')
if len(sys.argv)>1:tests=sys.argv[1:]
results=[]
for name in tests:
    extra=[];lib=['-y','rtl','-y','audio/src','-y','sim']
    if name=='tb_accomp_mix':lib=[];extra=['audio/src/score_accompaniment.v','audio/src/fsr16_engine.v','audio/src/freq_map.v']
    if name in ('tb_test_voices','tb_latency'):lib=[];extra=['audio/src/fsr32_engine.v','audio/src/fsr16_engine.v','audio/src/vib_lfo.v']
    target=OUT/(name+'.vvp')
    cmd=[str(IV),'-g2012','-o',str(target),'-s',name,'-I','rtl','-I','audio/src','-I','sim']+lib+['sim/'+name+'.v']+extra
    c=subprocess.run(cmd,cwd=P,capture_output=True,timeout=120)
    raw=c.stdout+c.stderr;ok=c.returncode==0
    if ok:
        try:
            v=subprocess.run([str(VVP),str(target)],cwd=P,capture_output=True,timeout=180)
            raw+=v.stdout+v.stderr; txt=v.stdout.decode('utf-8','replace')
            ok=v.returncode==0 and bool(re.search(r'PASS|ALL.*PASS|通过|OK',txt,re.I)) and not re.search(r'FAIL=[1-9]|\[FAIL\]|ERROR:|FATAL:|失败 [1-9]',txt,re.I)
        except subprocess.TimeoutExpired as e:raw+=(e.stdout or b'')+b'\nTIMEOUT';ok=False
    (OUT/(name+'.log')).write_bytes(raw)
    results.append(dict(name=name,ok=ok))
    print(name,'PASS' if ok else 'FAIL',flush=True)
if 'tb_sd_multiblock' in tests:
    v=subprocess.run([str(VVP),str(OUT/'tb_sd_multiblock.vvp'),'+spc=8'],cwd=P,capture_output=True,timeout=180)
    (OUT/'tb_sd_multiblock_spc8.log').write_bytes(v.stdout+v.stderr)
    ok=v.returncode==0 and b'FAIL=0' in v.stdout
    if not ok:ok=v.returncode==0 and re.search(rb'0 FAIL',v.stdout) is not None
    results.append(dict(name='tb_sd_multiblock_spc8',ok=ok))
(OUT/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
print('TOTAL',sum(x['ok'] for x in results),'/',len(results),flush=True)
sys.exit(0 if all(x['ok'] for x in results) else 1)
