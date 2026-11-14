#!/usr/bin/env python3
# move-proof.py OLD_HEAD_FILE NEW_FILE...: proves a split only moved code. Compares the statements of the file at HEAD with those of the new files, ignoring order, access levels, imports and whitespace. Only wrappers (extension X { and }) should be left.
import re,subprocess,sys,collections
old=sys.argv[1]; news=sys.argv[2:]
def norm(text):
    out=[]
    for l in text.split('\n'):
        l=l.strip()
        if not l or l.startswith('import '): continue
        l=re.sub(r'\b(fileprivate|private)(\(set\))? ','',l)
        out.append(l)
    return collections.Counter(out)
a=norm(subprocess.check_output(['git','show','HEAD:'+old],text=True))
b=collections.Counter()
for f in news: b+=norm(open(f).read())
minus=a-b; plus=b-a
print(old,'old',sum(a.values()),'new',sum(b.values()),'only-old',sum(minus.values()),'only-new',sum(plus.values()))
for k,v in list(minus.items())[:20]: print('  -',v,k[:130])
for k,v in list(plus.items())[:30]: print('  +',v,k[:130])
