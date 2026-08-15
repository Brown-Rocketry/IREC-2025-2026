"""
Flight data processing for RP2040 / Ada payload.

Expected input files, one value per line, in the same directory:
  TS.txt      timestamps, integer microseconds, 32-bit counter
  AX/AY/AZ    raw signed accelerometer counts
  P_hex.txt   raw pressure, hex, optionally "label: HEX"
  T_hex.txt   raw temperature, hex, same format
"""

import os
import math
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
SKIP = 54          # leading samples discarded (startup garbage)
START = 73885      # window start, in units of 5 samples
STOP = 73930       # window stop,  in units of 5 samples
STRIDE = 5         # multiplier used on START/STOP

FS_G = 16          # accelerometer full-scale setting actually programmed
LIFTOFF_G = 2.0    # magnitude threshold used to detect liftoff
PAD_GUARD = 3      # samples to leave between the pad window and liftoff
PAD_N = 20         # samples averaged for the pad baseline

# Pressure sanity band. Widened from the original 50-110 kPa so that a genuine
# ejection overpressure inside the airframe is reported rather than discarded.
P_MIN_PA = 30000.0
P_MAX_PA = 130000.0

SMOOTH_W = 5       # centered moving-average width for altitude smoothing
PLOT_LEAD_S = 5.0  # seconds of pad time to show before liftoff in the figure
PLOT_TAIL_S = 5.0  # seconds to show after the last valid altitude sample

G = 9.80665

# LSM9DS1 linear acceleration sensitivity, mg/LSB, from the datasheet.
# Note that +/-2, 4, 8 g match FS/32768 exactly and +/-16 g does not.
SENSITIVITY_MG_PER_LSB = {2: 0.061, 4: 0.122, 8: 0.244, 16: 0.732}

CAL_BYTES = [32, 109, 167, 77, 249, 205, 27, 77, 22, 6, 1, 61,
             76, 90, 92, 3, 250, 170, 15, 5, 245]

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def load_integers(filename):
    with open(os.path.join(HERE, filename), "r") as f:
        return [int(line.strip()) for line in f if line.strip()]


def load_hex(filename):
    values = []
    with open(os.path.join(HERE, filename), "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            hex_str = line.split(":")[1].strip() if ":" in line else line
            values.append(int(hex_str, 16))
    return values


def unwrap_timestamps(ts_raw, bit_depth=32):
    """Undo hardware counter rollover. A 32-bit microsecond counter wraps
    roughly every 71.6 minutes, so a 24 hour log contains many rollovers."""
    max_val = 1 << bit_depth
    half = max_val // 2
    out = []
    offset = 0
    prev = ts_raw[0] if ts_raw else 0
    for v in ts_raw:
        if (prev - v) > half:
            offset += max_val
        out.append(v + offset)
        prev = v
    return out


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------
def to_g(raw, fs_g=FS_G):
    return raw * SENSITIVITY_MG_PER_LSB[fs_g] / 1000.0


def parse_calibration(b):
    def u16(lo, hi): return lo | (hi << 8)

    def i16(lo, hi):
        v = u16(lo, hi)
        return v - 65536 if v >= 32768 else v

    def i8(x):
        return x - 256 if x >= 128 else x

    nvm = {
        "T1": u16(b[0], b[1]),   "T2": u16(b[2], b[3]),   "T3": i8(b[4]),
        "P1": i16(b[5], b[6]),   "P2": i16(b[7], b[8]),   "P3": i8(b[9]),
        "P4": i8(b[10]),         "P5": u16(b[11], b[12]), "P6": u16(b[13], b[14]),
        "P7": i8(b[15]),         "P8": i8(b[16]),         "P9": i16(b[17], b[18]),
        "P10": i8(b[19]),        "P11": i8(b[20]),
    }
    return {
        "T1": nvm["T1"] * 2**8,
        "T2": nvm["T2"] / 2**30,
        "T3": nvm["T3"] / 2**48,
        "P1": (nvm["P1"] - 2**14) / 2**20,
        "P2": (nvm["P2"] - 2**14) / 2**29,
        "P3": nvm["P3"] / 2**32,
        "P4": nvm["P4"] / 2**37,
        "P5": nvm["P5"] * 2**3,
        "P6": nvm["P6"] / 2**6,
        "P7": nvm["P7"] / 2**8,
        "P8": nvm["P8"] / 2**15,
        "P9": nvm["P9"] / 2**48,
        "P10": nvm["P10"] / 2**48,
        "P11": nvm["P11"] / 2**65,
    }


def compensate_temperature(raw_t, par):
    d1 = raw_t - par["T1"]
    return d1 * par["T2"] + (d1 * d1) * par["T3"]


def compensate_pressure(raw_p, t_lin, par):
    po1 = (par["P5"] + par["P6"] * t_lin + par["P7"] * t_lin**2
           + par["P8"] * t_lin**3)
    po2 = raw_p * (par["P1"] + par["P2"] * t_lin + par["P3"] * t_lin**2
                   + par["P4"] * t_lin**3)
    po3 = (raw_p**2) * (par["P9"] + par["P10"] * t_lin) + par["P11"] * raw_p**3
    return po1 + po2 + po3


def pressure_to_altitude(p_pa, p0_pa):
    return 44330.0 * (1.0 - (p_pa / p0_pa) ** (1.0 / 5.255))


def moving_average(series, width):
    """Centered moving average that skips NaN and preserves length."""
    half = width // 2
    out = []
    for i in range(len(series)):
        lo, hi = max(0, i - half), min(len(series), i + half + 1)
        vals = [v for v in series[lo:hi] if v == v]
        out.append(sum(vals) / len(vals) if vals else float("nan"))
    return out


def median(vals):
    s = sorted(vals)
    n = len(s)
    if n == 0:
        return float("nan")
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
lo, hi = STRIDE * START, STRIDE * STOP

ts_all = unwrap_timestamps(load_integers("TS.txt")[SKIP:])
total_s = (ts_all[-1] - ts_all[0]) / 1e6
print("=" * 62)
print("FULL LOG")
print(f"  samples            : {len(ts_all)}")
print(f"  duration           : {total_s:.1f} s  ({total_s/3600:.2f} h)")

dt_all = [(ts_all[i] - ts_all[i - 1]) / 1e6 for i in range(1, len(ts_all))]
dt_med_all = median(dt_all)
gaps = [(i, d) for i, d in enumerate(dt_all) if d > 2.0 * dt_med_all]
print(f"  median sample rate : {1.0/dt_med_all:.2f} Hz")
print(f"  max interval       : {max(dt_all)*1000:.1f} ms")
print(f"  intervals > 2x med : {len(gaps)}  <- evidence for the no-gaps claim")
if gaps[:5]:
    print(f"  first few gaps     : {[(i, round(d*1000,1)) for i, d in gaps[:5]]}")

ts = ts_all[lo:hi]
ax_raw = load_integers("AX.txt")[SKIP:][lo:hi]
ay_raw = load_integers("AY.txt")[SKIP:][lo:hi]
az_raw = load_integers("AZ.txt")[SKIP:][lo:hi]
p_raw = load_hex("P_hex.txt")[SKIP:][lo:hi]
t_raw = load_hex("T_hex.txt")[SKIP:][lo:hi]

n = min(len(ts), len(ax_raw), len(ay_raw), len(az_raw), len(p_raw), len(t_raw))
t0 = ts[0]
time = [(v - t0) / 1e6 for v in ts[:n]]

dt_win = [time[i] - time[i - 1] for i in range(1, n)]
dt_med = median(dt_win)
print("\nFLIGHT WINDOW")
print(f"  samples            : {n}")
print(f"  duration           : {time[-1]:.2f} s")
print(f"  median sample rate : {1.0/dt_med:.2f} Hz")
print(f"  interval min/max   : {min(dt_win)*1000:.1f} / {max(dt_win)*1000:.1f} ms")

# ---------------------------------------------------------------------------
# Accelerometer
# ---------------------------------------------------------------------------
x_g = [to_g(v) for v in ax_raw[:n]]
y_g = [to_g(v) for v in ay_raw[:n]]
z_g = [to_g(v) for v in az_raw[:n]]
mag = [math.sqrt(a*a + b*b + c*c) for a, b, c in zip(x_g, y_g, z_g)]

print("\nACCELEROMETER")
print(f"  FS setting         : +/-{FS_G} g")
print(f"  sensitivity used   : {SENSITIVITY_MG_PER_LSB[FS_G]} mg/LSB")
print(f"  word spans         : +/-{SENSITIVITY_MG_PER_LSB[FS_G]*32768/1000:.1f} g")

# Liftoff detection
liftoff_i = next((i for i, m in enumerate(mag) if m > LIFTOFF_G), None)
if liftoff_i is None:
    raise SystemExit("No liftoff detected. Lower LIFTOFF_G or widen the window.")
print(f"  liftoff at         : index {liftoff_i}, t = {time[liftoff_i]:.2f} s")

pad_hi = max(0, liftoff_i - PAD_GUARD)
pad_lo = max(0, pad_hi - PAD_N)
pad_mag = sum(mag[pad_lo:pad_hi]) / max(1, pad_hi - pad_lo)
print(f"  pad |a| magnitude  : {pad_mag:.3f} g   <- MUST be ~1.000")
if abs(pad_mag - 1.0) > 0.05:
    print("  WARNING: pad magnitude is not 1 g. Scale factor or FS setting is wrong.")

peak_mag = max(mag)
peak_i = mag.index(peak_mag)
boost_end = min(n, liftoff_i + int(3.0 / dt_med))
boost_peak = max(mag[liftoff_i:boost_end])
print(f"  peak |a| overall   : {peak_mag:.2f} g at t = {time[peak_i]:.2f} s")
print(f"  peak |a| in boost  : {boost_peak:.2f} g")
over_spec = sum(1 for m in mag if m > FS_G)
if over_spec:
    print(f"  samples above +/-{FS_G} g : {over_spec}  <- OUTSIDE the specified"
          f" linear range, treat as indicative only")

# ---------------------------------------------------------------------------
# Barometer
# ---------------------------------------------------------------------------
par = parse_calibration(CAL_BYTES)
t_c = [compensate_temperature(v, par) for v in t_raw[:n]]
p_pa = [compensate_pressure(rp, tt, par) for rp, tt in zip(p_raw[:n], t_c)]

rejected = [(i, p_raw[i], p_pa[i]) for i in range(n)
            if not (P_MIN_PA < p_pa[i] < P_MAX_PA)]
print("\nBAROMETER")
print(f"  rejected samples   : {len(rejected)} of {n}")
for i, raw, pa in rejected[:12]:
    print(f"    t={time[i]:7.3f} s  raw=0x{raw:06X}  compensated={pa:,.0f} Pa")
if rejected:
    print("  Inspect these. Wild values mean a failed read. Values just above")
    print("  the band may be a real ejection overpressure worth keeping.")

p_clean = [p if P_MIN_PA < p < P_MAX_PA else float("nan") for p in p_pa]


def apogee_for(pad_n, guard):
    a = max(0, liftoff_i - guard - pad_n)
    b = max(0, liftoff_i - guard)
    samples = [p for p in p_clean[a:b] if p == p]
    if not samples:
        return None, None
    p0 = sum(samples) / len(samples)
    alt = [pressure_to_altitude(p, p0) if p == p else float("nan")
           for p in p_clean]
    valid = [v for v in alt if v == v]
    return (max(valid) if valid else None), p0


apogees = []
for pn in (10, 20, 30):
    for gd in (2, 5, 10):
        a, _ = apogee_for(pn, gd)
        if a is not None:
            apogees.append(a)

apogee, P0 = apogee_for(PAD_N, PAD_GUARD)
altitude = [pressure_to_altitude(p, P0) if p == p else float("nan")
            for p in p_clean]

# Ejection overpressure. In flight the airframe cannot be below the pad, so a
# strongly negative altitude means measured pressure ABOVE the pad baseline.
# That is a real physical event, not a bad read, but it must be excluded from
# the altitude trace used for velocity or it swamps the derivative.
OVERP_ALT_M = -50.0
overp = set(i for i, a in enumerate(altitude)
            if a == a and a < OVERP_ALT_M and i > liftoff_i)
altitude_flight = [float("nan") if i in overp else a
                   for i, a in enumerate(altitude)]

print(f"  pad pressure P0    : {P0:,.1f} Pa "
      f"(mean of {PAD_N} samples ending {PAD_GUARD} before liftoff)")
print(f"  apogee             : {apogee:.1f} m AGL")
if apogees:
    print(f"  apogee across {len(apogees)} baseline choices: "
          f"{min(apogees):.1f} to {max(apogees):.1f} m "
          f"(spread {max(apogees)-min(apogees):.1f} m)")
    print("  Quote apogee to the precision this spread supports, not 0.1 m.")

if overp:
    idx = sorted(overp)
    pk = max(p_pa[i] for i in idx)
    print(f"  overpressure event : {len(idx)} sample(s) from "
          f"t = {time[idx[0]]:.2f} to {time[idx[-1]]:.2f} s")
    print(f"    peak pressure    : {pk/1000:.1f} kPa")
    print(f"    above pad by     : {(pk-P0)/1000:.1f} kPa "
          f"({(pk-P0)*0.000145038:.2f} psi)")
    print("    Cross-check the accelerometer at the same timestamps. Matching")
    print("    shock plus overpressure means ejection, not a failed read.")

# ---------------------------------------------------------------------------
# Vertical velocity
# ---------------------------------------------------------------------------
alt_smooth = moving_average(altitude_flight, SMOOTH_W)


def diff(series):
    out = [float("nan")]
    for i in range(1, len(series)):
        a0, a1 = series[i - 1], series[i]
        d = time[i] - time[i - 1]
        out.append((a1 - a0) / d if d > 0 and a0 == a0 and a1 == a1
                   else float("nan"))
    return out


vz_raw = diff(altitude_flight)
vz = diff(alt_smooth)

apogee_i = max(range(n),
               key=lambda i: altitude_flight[i]
               if altitude_flight[i] == altitude_flight[i] else -1e12)
ascent = [vz[i] for i in range(liftoff_i, apogee_i + 1) if vz[i] == vz[i]]
descent = [vz[i] for i in range(apogee_i + 1, n) if vz[i] == vz[i]]

print("\nVERTICAL VELOCITY (differentiated barometric altitude)")
print(f"  apogee at          : t = {time[apogee_i]:.2f} s")
print(f"  peak ascent rate   : {max(ascent):.1f} m/s   <- quote this one")
if descent:
    print(f"  mean descent rate  : {sum(descent)/len(descent):.1f} m/s "
          f"(under canopy)")
vz_raw_valid = [v for v in vz_raw if v == v]
print(f"  peak, unsmoothed   : {max(vz_raw_valid):.1f} m/s  <- single-sample "
      f"artifact, do not quote")

# ---------------------------------------------------------------------------
# Physics consistency checks. A barometer at a few Hz cannot resolve a boost
# that lasts about a second, so the differentiated peak is unreliable in both
# directions: transients inflate it and smoothing attenuates it. These two
# independent checks bound the true burnout speed from the apogee and the
# coast time, which are both robust.
# ---------------------------------------------------------------------------
coast_s = time[apogee_i] - time[liftoff_i]
v_from_apogee = math.sqrt(2 * G * apogee)
v_from_coast = G * coast_s
v_peak = max(ascent)

print("\nCONSISTENCY CHECKS")
print(f"  liftoff -> apogee  : {coast_s:.2f} s")
print(f"  burnout speed implied by apogee ({apogee:.0f} m) : "
      f">= {v_from_apogee:.1f} m/s")
print(f"  burnout speed implied by coast time             : "
      f">= {v_from_coast:.1f} m/s")
print(f"  drag-free apogee implied by peak ascent rate    : "
      f"{v_peak**2 / (2*G):.0f} m")
if v_peak**2 / (2 * G) > 2.0 * apogee:
    print("  MISMATCH: the quoted peak ascent rate implies an apogee far above")
    print("  the measured one. It is a liftoff pressure transient, not airspeed.")
    print(f"  Treat true burnout speed as roughly {v_from_apogee:.0f} to "
          f"{1.3*v_from_apogee:.0f} m/s and do not quote the barometric peak.")
elif v_peak < 0.8 * v_from_apogee:
    print("  Peak ascent rate is below what the apogee requires. Smoothing at")
    print("  this sample rate is attenuating the real peak. Do not quote it.")
else:
    print("  Peak ascent rate is consistent with the measured apogee.")

# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------
fig, (a1, a2, a3) = plt.subplots(3, 1, figsize=(11, 13), sharex=True)

ejection_t = time[sorted(overp)[0]] if overp else None


def mark_ejection(axis):
    if ejection_t is not None:
        axis.axvline(ejection_t, color="C1", ls="--", lw=1, alpha=0.8)


a1.plot(time, altitude_flight, color="C3", lw=1.4,
        label=f"Barometric altitude (apogee {apogee:.0f} m AGL)")
a1.axvline(time[liftoff_i], color="0.6", ls="--", lw=1)
a1.annotate("liftoff", (time[liftoff_i], 0), textcoords="offset points",
            xytext=(5, 12), fontsize=9, color="0.35")
mark_ejection(a1)
if ejection_t is not None:
    a1.annotate("ejection\n(overpressure masked)", (ejection_t, apogee * 0.55),
                textcoords="offset points", xytext=(8, 0), fontsize=8,
                color="C1")
a1.set_ylim(-30, apogee * 1.15)
a1.set_ylabel("Altitude AGL (m)")
a1.set_title("Barometric altitude, pad-referenced")
a1.legend(loc="lower right", fontsize=9)
a1.grid(True, alpha=0.3)

mean_descent = sum(descent) / len(descent) if descent else float("nan")
a2.plot(time, vz, color="C4", lw=1.4,
        label=f"Vertical velocity, {SMOOTH_W}-sample smoothed "
              f"(descent {abs(mean_descent):.1f} m/s under canopy)")
mark_ejection(a2)
a2.annotate("ascent peak not resolved\nat this sample rate",
            (time[liftoff_i], max(ascent) * 0.85),
            textcoords="offset points", xytext=(14, 0), fontsize=8,
            color="0.35")
a2.set_ylim(min(-40, min(descent) * 1.4 if descent else -40),
            max(ascent) * 1.3)
a2.set_ylabel("Vertical velocity (m/s)")
a2.set_title("Vertical velocity, differentiated from smoothed altitude")
a2.legend(loc="upper right", fontsize=9)
a2.grid(True, alpha=0.3)

a3.plot(time, x_g, lw=1.0, label="X")
a3.plot(time, y_g, lw=1.0, label="Y")
a3.plot(time, z_g, lw=1.0, label="Z")
a3.plot(time, mag, lw=1.6, color="k", alpha=0.75, label="|a|")
mark_ejection(a3)
a3.axhline(FS_G, color="r", ls=":", lw=1)
a3.axhline(-FS_G, color="r", ls=":", lw=1)
a3.annotate(f"specified +/-{FS_G} g range", (time[0], FS_G),
            textcoords="offset points", xytext=(6, 5), fontsize=8, color="r")
a3.set_ylabel("Acceleration (g)")
a3.set_xlabel("Time (s)")
a3.set_title(f"Accelerometer, {SENSITIVITY_MG_PER_LSB[FS_G]} mg/LSB "
             f"(datasheet FS +/-{FS_G} g)")
a3.legend(loc="upper right", fontsize=9, ncol=4)
a3.grid(True, alpha=0.3)

last_valid = max(i for i in range(n)
                 if altitude_flight[i] == altitude_flight[i])
a3.set_xlim(max(time[0], time[liftoff_i] - PLOT_LEAD_S),
            min(time[-1], time[last_valid] + PLOT_TAIL_S))

fig.suptitle("High-power rocket payload flight data, RP2040 bare-metal Ada",
             fontsize=13, y=0.995)
plt.tight_layout()
out = os.path.join(HERE, "flight_plot.png")
plt.savefig(out, dpi=160)
print(f"\nPlot written to {out}")
print("=" * 62)