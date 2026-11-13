"""Render Pro-C / Pro-C 2 with overrides (cached, parallel) and compare.

Work happens in $PROC_LAB (default: ./lab): test signals in sig/, renders cached in
cache/, measurements written beside them. Needs plugin-lab's auhost built x86_64.
"""
import hashlib, os, subprocess, sys, uuid
from concurrent.futures import ThreadPoolExecutor
import numpy as np
LAB = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../plugin-lab'))
sys.path.insert(0, os.path.join(LAB, 'scripts'))
from wav import read
from compare import align, loudness, db, rms

AUHOST = os.path.join(LAB, '.build/x86_64-apple-macosx/release/auhost')
HERE = os.path.abspath(os.environ.get('PROC_LAB', 'lab'))
C1, C2 = 'aumf:FPrC:FabF', 'aumf:FC2p:FabF'
os.makedirs(f'{HERE}/cache', exist_ok=True)


def render(plugin, signal, overrides=None):
    """plugin: codes or a state plist. overrides: {name: value}. Returns the output path."""
    args = [f'{k}={v:.6g}' if isinstance(v, float) else f'{k}={v}' for k, v in (overrides or {}).items()]
    key = hashlib.md5(repr((plugin, signal, args, os.path.getmtime(plugin) if plugin.endswith('.plist') else 0)).encode()).hexdigest()
    out = f'{HERE}/cache/{key}.wav'
    if not os.path.exists(out):
        tmp = f'{out}.{uuid.uuid4().hex}.wav'
        r = subprocess.run([AUHOST, 'render', plugin, f'{HERE}/sig/{signal}.wav', tmp, *args],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(tmp):
            raise RuntimeError(r.stdout + r.stderr)
        os.replace(tmp, out)
    return out


def render_all(jobs, workers=os.cpu_count()):
    with ThreadPoolExecutor(workers) as ex:
        return list(ex.map(lambda j: render(*j), jobs))


def null(a_path, b_path):
    """Residual (dB) of b against a, without and with best gain; loudness difference."""
    a, b = read(a_path), read(b_path)
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    raw = db(rms(a - b)) - db(rms(a))
    _, g, res = align(a, b, maxlag=64)
    return raw, res, loudness(b) - loudness(a)


def step_levels(path, steps=11, seconds=2, sr=48000):
    """Output level (dB) over the last half of each 2 s tone step."""
    x = read(path).mean(1)
    seg = seconds * sr
    return np.array([db(rms(x[i * seg + seg // 2:(i + 1) * seg])) + 3.01 for i in range(steps)])


def _table(path):
    xs, ms = [], []
    for line in open(path):
        x, txt = line.split('\t')
        v, unit = txt.split()[:2]
        xs.append(float(x)); ms.append(float(v) * (1000 if unit.startswith('sec') else 1))
    return np.array(xs), np.array(ms)


def strings(plugin, name, steps=100):
    """`auhost strings`: the plugin's display text across a parameter's range."""
    path = f'{HERE}/{plugin.split(":")[1]}_{name.replace(" ", "_").lower()}.txt'
    if not os.path.exists(path):
        r = subprocess.run([AUHOST, 'strings', plugin, name, str(steps)], capture_output=True, text=True, check=True)
        open(path, 'w').write(r.stdout)
    return path


os.makedirs(f'{HERE}/sig', exist_ok=True)
C1_REL = _table(strings(C1, 'Release'))
C2_REL = _table(strings(C2, 'Release'))


def c1_attack_ms(x): return 0.5 + 499.5 * x ** 4
def c2_attack_x(ms): return float(np.clip(((ms - 0.005) / 250) ** (1 / 3), 0, 1))
def c1_release_ms(x): return float(np.exp(np.interp(x, C1_REL[0], np.log(C1_REL[1]))))
def c2_release_x(ms): return float(np.interp(np.log(ms), np.log(C2_REL[1]), C2_REL[0]))
