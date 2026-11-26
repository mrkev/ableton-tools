# Builds OrbitGainTable.swift from the renders in ./grid: python3 gen_table.py <this folder> <output.swift>
import sys,os; D=sys.argv[1]; OUT=sys.argv[2]; sys.path.insert(0,D); from wav import *
N=1<<16; f=np.fft.rfftfreq(N,1/48000); z=np.exp(-2j*np.pi*f/48000)
def biq(b,a): return (b[0]+b[1]*z+b[2]*z*z)/(a[0]+a[1]*z+a[2]*z*z)
# ITU-R BS.1770 K-weighting at 48 kHz, applied to pink noise.
K=np.abs(biq([1.53512485958697,-2.69169618940638,1.19839281085285],[1,-1.69065929318241,0.73248077342364])*biq([1,-2,1],[1,-1.99004745483398,0.99007225036621]))**2
W=K*np.where(f>20,1/np.maximum(f,1),0)
def E(p): return (np.abs(np.fft.rfft(read(p),N,axis=0))**2).sum(1).dot(W)
def gain(n): return 10*np.log10(E(f"{D}/grid/o_{n}.wav")/E(f"{D}/grid/m_{n}.wav"))
AZ=list(range(-180,180,15)); EL=[-90,-60,-30,0,30,60,90]; WI=[0,25,50,75,100]; CL=[0,25,50,75,100]
vals=[gain(f"a{a}_e{e}_w{w}_c{c}") for a in AZ for e in EL for w in WI for c in CL]
a=np.array(vals); print("grid", a.min().round(2), a.max().round(2), a.mean().round(2), "n", len(a))
for n in sorted(x[2:-4] for x in os.listdir(f"{D}/grid") if x.startswith("o_rev")): print(n, round(gain(n),2))
# Reflections: the extra makeup with them on, by level, averaged over positions and rooms.
LV=[-10,0,10]; azr=[0,45,90,135]
corr=[]
for l in LV:
    d=[gain(f"rev_a{a}_l{l}_r{r}")-gain(f"rev_a{a}_off") for a in azr for r in [0,4]]
    corr.append(float(np.mean(d))); print("reflection level",l,"mean",round(np.mean(d),2),"spread",round(min(d),2),round(max(d),2))
rows=[]
for i,a_ in enumerate(AZ):
    chunk=vals[i*len(EL)*len(WI)*len(CL):(i+1)*len(EL)*len(WI)*len(CL)]
    rows.append(f"    // azimuth {a_}\n    " + ", ".join(f"{v:.2f}" for v in chunk) + ",")
open(OUT,"w").write(f'''import Foundation

/// How much quieter dearVR MICRO (AMBEO HRTF, Focus 100) is than AMBEO Orbit at
/// the same settings, in dB: the gain that restores Orbit's loudness.
///
/// Measured offline: both plugins rendered an impulse at every grid point, and
/// the loudness of each response was compared as pink noise through the
/// ITU-R BS.1770 K-weighting filter. The renderer reproduces Live's own bounces
/// of both plugins exactly. The grid is without reflections; turning them on adds
/// a little, by reflection level, which is averaged over positions and rooms
/// (each within 0.5 dB of it). See `Calibration/OrbitToMicro`.
enum OrbitGainTable {{
  static let azimuths: [Double] = {AZ}
  static let elevations: [Double] = {EL}
  static let widths: [Double] = {WI}
  static let clarities: [Double] = {CL}

  static let reflectionLevels: [Double] = {LV}
  static let reflectionCorrections: [Double] = [{", ".join(f"{c:.2f}" for c in corr)}]

  /// Linear between grid points; azimuth wraps around. `reflectionLevel` is `nil`
  /// with reflections off.
  static func makeupDb(
    azimuth: Double, elevation: Double, width: Double, clarity: Double, reflectionLevel: Double?
  ) -> Double {{
    var correction = 0.0
    if let level = reflectionLevel {{
      let (ri, rf) = locate(level, in: reflectionLevels)
      correction = reflectionCorrections[ri] * (1 - rf) + reflectionCorrections[ri + 1] * rf
    }}
    return correction + positionDb(azimuth: azimuth, elevation: elevation, width: width, clarity: clarity)
  }}

  private static func positionDb(azimuth: Double, elevation: Double, width: Double, clarity: Double) -> Double {{
    let a = wrapped(azimuth)
    let ai = min(Int((a + 180) / 15), azimuths.count - 1)
    let af = (a - azimuths[ai]) / 15
    let (ei, ef) = locate(elevation, in: elevations)
    let (wi, wf) = locate(width, in: widths)
    let (ci, cf) = locate(clarity, in: clarities)
    var total = 0.0
    for (da, wa) in [(0, 1 - af), (1, af)] where wa > 0 {{
      for (de, we) in [(0, 1 - ef), (1, ef)] where we > 0 {{
        for (dw, ww) in [(0, 1 - wf), (1, wf)] where ww > 0 {{
          for (dc, wc) in [(0, 1 - cf), (1, cf)] where wc > 0 {{
            total += wa * we * ww * wc * value((ai + da) % azimuths.count, ei + de, wi + dw, ci + dc)
          }}
        }}
      }}
    }}
    return total
  }}

  private static func wrapped(_ degrees: Double) -> Double {{
    var a = degrees.truncatingRemainder(dividingBy: 360)
    if a < -180 {{ a += 360 }}
    if a >= 180 {{ a -= 360 }}
    return a
  }}

  /// The grid cell holding `x` (clamped) and the fraction of the way across it.
  private static func locate(_ x: Double, in grid: [Double]) -> (Int, Double) {{
    let v = min(max(x, grid[0]), grid[grid.count - 1])
    let i = min(grid.lastIndex {{ $0 <= v }} ?? 0, grid.count - 2)
    return (i, (v - grid[i]) / (grid[i + 1] - grid[i]))
  }}

  private static func value(_ a: Int, _ e: Int, _ w: Int, _ c: Int) -> Double {{
    Double(table[((a * elevations.count + e) * widths.count + w) * clarities.count + c])
  }}

  /// [azimuth][elevation][width][clarity]
  private static let table: [Float] = [
{chr(10).join(rows)}
  ]
}}
''')
print("wrote",OUT)
