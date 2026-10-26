import json, pathlib
root=pathlib.Path(__file__).resolve().parent
rows={}
for mode,stem in [('image_local','lorenz'),('transferred','lorenz-transfer')]:
    directory=root/'build'/stem
    lib=directory/'liblorenz.so'
    if lib.exists():
        rows[mode]={'library_bytes':lib.stat().st_size,'trim':'safe'}
        state=directory/'states.jls'
        if state.exists(): rows[mode]['serialized_bytes']=state.stat().st_size
rows['wasm_gc']=json.loads((root/'build/lorenz/lorenz-wasm-stats.json').read_text())
(root/'results/artifacts.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(rows,indent=2))

import hashlib
source=root/'LorenzProgram.jl'
kernel=(root/'build/lorenz/lorenz-wasm-wrappers.jl').read_text()
for stem in ('lorenz','lorenz-transfer'):
    image=(root/'build'/stem/'build.jl').read_text()
    assert kernel in image
    assert str(source.resolve()) in image
counts={str(p.relative_to(root)):len(p.read_text().splitlines()) for p in sorted((root/'ProgramBuild/src').glob('*.jl'))}
shared=counts['ProgramBuild/src/ProgramBuild.jl']
wasm=counts['ProgramBuild/src/wasm.jl']
native=counts['ProgramBuild/src/native.jl']+counts['ProgramBuild/src/transfer.jl']
evidence={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
          'same_program_source_both_native_modes':True,'same_kernel_all_targets':True,
          'physical_lines_including_blanks_comments':counts,
          'shared':shared,'wasm_specific':wasm,'native_specific':native,
          'framework_total':shared+wasm+native,'program_lines':len(source.read_text().splitlines())}
(root/'results/sharing.json').write_text(json.dumps(evidence,indent=2)+'\n')
