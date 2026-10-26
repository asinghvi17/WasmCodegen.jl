import json, pathlib
root=pathlib.Path(__file__).resolve().parent
ref=json.loads((root/'build/lorenz/julia.json').read_text())
native=json.loads((root/'build/lorenz/native-points.json').read_text())
wasm=json.loads((root/'build/lorenz/wasm-points.json').read_text())
def compare(a,b):
    assert len(a)==len(b)==2
    diffs=[]
    for x,y in zip(a,b):
        assert len(x)==len(y)==401
        for rx,ry in zip(x,y):
            assert len(rx)==len(ry)==3
            for vx,vy in zip(rx,ry):
                assert abs(vx-vy)<=1e-7+1e-8*abs(vy),(vx,vy)
                diffs.append(abs(vx-vy))
    return {'comparisons':len(diffs),'max_absolute_error':max(diffs)}
plain=[r['points'] for r in ref]
result={'native_vs_julia':compare(native,plain),'wasm_vs_julia':compare(wasm,plain),
        'wasm_vs_native':compare(wasm,native)}
transfer=root/'build/lorenz-transfer/native-points.json'
if transfer.exists(): result['transferred_vs_julia']=compare(json.loads(transfer.read_text()),plain)
manifest=json.loads((root/'build/lorenz/lorenz.json').read_text())
assert 'wasm_gc' in manifest['targets'] and 'native' in manifest['targets']
print(json.dumps(result,indent=2)); (root/'results/trajectories.json').write_text(json.dumps(result,indent=2)+'\n')
