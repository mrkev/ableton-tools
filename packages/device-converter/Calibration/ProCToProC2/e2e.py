#!/usr/bin/env python3
"""End-to-end check of converted sets: render each original Pro-C device and the
Pro-C 2 device the converter wrote in its place, and compare.

    e2e.py <signal.wav> <original.als> <converted.als> [<original.als> <converted.als> ...]

Pairs devices in document order. Also checks the converted device's parameter
slots show the values Pro-C 2 actually holds. Needs plugin-lab's auhost (x86_64).
"""
import gzip, os, plistlib, re, subprocess, sys, tempfile, binascii
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.normpath(os.path.join(HERE, '../../../plugin-lab'))
sys.path.insert(0, os.path.join(LAB, 'scripts'))
from compare import align, loudness, db, rms  # noqa: E402
from wav import read  # noqa: E402

AUHOST = os.path.join(LAB, '.build/x86_64-apple-macosx/release/auhost')
PROC, PROC2 = '1179677251', '1178808944'


def states(path, subtype):
    root = ET.fromstring(gzip.open(path).read())
    out = []
    for d in root.iter('AuPluginDevice'):
        info = d.find('PluginDesc/AuPluginInfo')
        if info.find('ComponentSubType').get('Value') != subtype:
            continue
        buf = binascii.unhexlify(re.sub(r'\s', '', info.find('Preset/AuPreset/Buffer').text))
        slots = [(p.find('ParameterName').get('Value'), int(p.find('ParameterId').get('Value')),
                  float(p.find('ParameterValue/Manual').get('Value')))
                 for p in d.find('ParameterList') if p.find('ParameterId').get('Value') != '-1']
        out.append((plistlib.loads(buf), slots))
    return out


def render(state, signal, tmp, name):
    plist = os.path.join(tmp, name + '.plist')
    plistlib.dump(state, open(plist, 'wb'))
    wav = os.path.join(tmp, name + '.wav')
    subprocess.run([AUHOST, 'render', plist, signal, wav], check=True, capture_output=True)
    return plist, wav


def params(plist):
    out = {}
    for line in subprocess.run([AUHOST, 'params', plist], capture_output=True, text=True).stdout.splitlines()[1:]:
        f = line.split('\t')
        lo, hi = (float(x) for x in f[3].strip('[]').split(' … '))
        out[int(f[0])] = (f[1], float(f[2]), lo, hi)
    return out


def main(signal, pairs):
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for k, (orig, conv) in enumerate(pairs):
            a, b = states(orig, PROC), states(conv, PROC2)
            if len(a) != len(b) or states(conv, PROC):
                print(f'{conv}: {len(a)} Pro-C in, {len(b)} Pro-C 2 out, {len(states(conv, PROC))} Pro-C left')
                rows.append(None)
                continue
            for i, ((s1, _), (s2, slots)) in enumerate(zip(a, b)):
                _, w1 = render(s1, signal, tmp, f'{k}_{i}_c1')
                p2, w2 = render(s2, signal, tmp, f'{k}_{i}_c2')
                x, y = read(w1), read(w2)
                n = min(len(x), len(y))
                raw = db(rms(x[:n] - y[:n])) - db(rms(x[:n]))
                loud = loudness(y[:n]) - loudness(x[:n])
                held = params(p2)
                bad = [name for name, pid, manual in slots
                       if pid in held and abs((held[pid][1] - held[pid][2]) / (held[pid][3] - held[pid][2]) - manual) > 1e-3]
                rows.append((raw, loud))
                print(f'{os.path.basename(conv)} #{i}: loudness {loud:+.2f} dB, null {raw:.1f} dB'
                      + (f', slots off: {bad}' if bad else f', {len(slots)} slots match'))
    ok = [r for r in rows if r]
    if ok:
        nulls = sorted(r[0] for r in ok)
        louds = sorted(abs(r[1]) for r in ok)
        print(f'\n{len(ok)} devices: null median {nulls[len(nulls) // 2]:.1f} dB, worst {nulls[-1]:.1f};'
              f' |loudness| median {louds[len(louds) // 2]:.2f} dB, worst {louds[-1]:.2f}')
    return 0 if len(ok) == len(rows) else 1


if __name__ == '__main__':
    if len(sys.argv) < 4 or len(sys.argv) % 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], list(zip(sys.argv[2::2], sys.argv[3::2]))))
