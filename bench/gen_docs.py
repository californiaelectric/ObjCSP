# gen_docs.py -- makes the documents for the docs benchmark: 2,000 text
# files of made-up words, 300 to 3,000 words each (about 2-20 KB), and the
# 9 category word lists. Each document leans toward one category, so the
# sorting has a right answer. The same every time.
#
#     python3 gen_docs.py data
import os, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'data'
os.makedirs(os.path.join(out, 'docs'), exist_ok=True)

x = 42
def rand(n):                                 # a small LCG: 0 <= result < n
    global x
    x = (x * 6364136223846793005 + 1442695040888963407) % (1 << 64)
    return (x >> 33) % n

syllables = ['ka', 'lo', 'mi', 'nu', 're', 'sa', 'to', 'vi', 'ze', 'po',
             'ri', 'da', 'fe', 'gu', 'ho', 'ja', 'ke', 'lu', 'mo', 'ne']
words = set()
while len(words) < 3000:
    words.add(''.join(syllables[rand(len(syllables))] for _ in range(2 + rand(3))))
words = sorted(words)

categories = []
for c in range(9):
    categories.append(sorted({words[rand(len(words))] for _ in range(40)}))
with open(os.path.join(out, 'categories.txt'), 'w') as f:
    for c in categories:
        f.write(' '.join(c) + '\n')

for d in range(2000):
    lean = categories[rand(9)]
    n = 300 + rand(2701)
    doc = []
    for _ in range(n):
        if rand(100) < 6:
            doc.append(lean[rand(len(lean))])
        else:
            # common words come up far more often than rare ones
            doc.append(words[rand(1 + rand(len(words)))])
    with open(os.path.join(out, 'docs', 'doc%04d.txt' % d), 'w') as f:
        f.write(' '.join(doc))
