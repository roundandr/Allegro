"""Inspect the actual synthesized memory cells, including their physical ports."""
import json
from pathlib import Path
import sys


def check(directory):
    results={}
    for name,expected_banks,expected_bits in (('tmem',128,256*1024*8),('smem',32,228*1024*8)):
        design=json.loads((directory/f'{name}.json').read_text())
        cells=design['modules']['blackwell_banked_sram']['cells']
        memory=[cell for cell in cells.values() if cell['type']=='$mem_v2']
        assert len(memory)==expected_banks,(name,len(memory))
        bits=0;shapes=[]
        for cell in memory:
            p=cell['parameters']
            number=lambda field:int(p[field],2)
            width,depth=number('WIDTH'),number('SIZE')
            bits+=width*depth
            assert number('RD_PORTS')==1,(name,'read ports',p['RD_PORTS'])
            assert number('WR_PORTS')==1,(name,'write ports',p['WR_PORTS'])
            assert number('RD_CLK_ENABLE')==number('WR_CLK_ENABLE')==1
            assert set(p['INIT'])=={'x'},'storage acquired a reset/init value'
            shapes.append((depth,width))
        assert bits==expected_bits,(name,bits,expected_bits)
        results[name]={'banks':len(memory),'storage_bits':bits,'storage_bytes':bits//8,
                       'bank_shapes':sorted(set(shapes)),'ports_per_bank':'1R1W',
                       'initialized':False,'evidence':'Yosys memory_dff + memory_share + memory_collect'}
    (directory/'memory-structure.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))


if __name__=='__main__':check(Path(sys.argv[1]))
