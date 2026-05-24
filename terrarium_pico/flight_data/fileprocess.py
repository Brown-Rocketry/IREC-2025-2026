import os
import matplotlib.pyplot as plt

def load_integers(filename):
    path = os.path.join(os.path.dirname(__file__), filename)
    with open(path, 'r') as f:
        return [int(line.strip()) for line in f if line.strip()]

def load_hex_bmp(filename, prefix):
    path = os.path.join(os.path.dirname(__file__), filename)
    values = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if ':' in line:
                hex_str = line.split(':')[1].strip()
            else:
                hex_str = line.strip()
            values.append(int(hex_str, 16))
    return values

def to_g(raw, scale=16):
    return raw / (32768 / scale)

# ---------------------------------------------------------------------------
# BMP390 calibration coefficients
# ---------------------------------------------------------------------------
CAL_BYTES = [32, 109, 167, 77, 249, 205, 27, 77, 22, 6, 1, 61, 76, 90, 92, 3, 250, 170, 15, 5, 245]

def parse_calibration(raw_bytes):
    def u16(lo, hi): return lo | (hi << 8)
    def i16(lo, hi):
        v = u16(lo, hi)
        return v - 65536 if v >= 32768 else v
    def i8(b):
        return b - 256 if b >= 128 else b

    b = raw_bytes
    nvm = {
        'T1':  u16(b[0],  b[1]),
        'T2':  u16(b[2],  b[3]),
        'T3':  i8 (b[4]),
        'P1':  i16(b[5],  b[6]),
        'P2':  i16(b[7],  b[8]),
        'P3':  i8 (b[9]),
        'P4':  i8 (b[10]),
        'P5':  u16(b[11], b[12]),
        'P6':  u16(b[13], b[14]),
        'P7':  i8 (b[15]),
        'P8':  i8 (b[16]),
        'P9':  i16(b[17], b[18]),
        'P10': i8 (b[19]),
        'P11': i8 (b[20]),
    }

    par = {
        'T1':  nvm['T1']  * 2**8,
        'T2':  nvm['T2']  / 2**30,
        'T3':  nvm['T3']  / 2**48,
        'P1': (nvm['P1'] - 2**14) / 2**20,
        'P2': (nvm['P2'] - 2**14) / 2**29,
        'P3':  nvm['P3']  / 2**32,
        'P4':  nvm['P4']  / 2**37,
        'P5':  nvm['P5']  * 2**3,
        'P6':  nvm['P6']  / 2**6,
        'P7':  nvm['P7']  / 2**8,
        'P8':  nvm['P8']  / 2**15,
        'P9':  nvm['P9']  / 2**48,
        'P10': nvm['P10'] / 2**48,
        'P11': nvm['P11'] / 2**65,
    }
    return par

def compensate_temperature(raw_T, par):
    pd1 = raw_T - par['T1']
    pd2 = pd1 * par['T2']
    t_lin = pd2 + (pd1 * pd1) * par['T3']
    return t_lin

def compensate_pressure(raw_P, t_lin, par):
    pd1 = par['P6'] * t_lin
    pd2 = par['P7'] * t_lin * t_lin
    pd3 = par['P8'] * t_lin * t_lin * t_lin
    po1 = par['P5'] + pd1 + pd2 + pd3

    pd1 = par['P2'] * t_lin
    pd2 = par['P3'] * t_lin * t_lin
    pd3 = par['P4'] * t_lin * t_lin * t_lin
    po2 = raw_P * (par['P1'] + pd1 + pd2 + pd3)

    pd1 = raw_P * raw_P
    pd2 = par['P9'] + par['P10'] * t_lin
    pd3 = pd1 * pd2
    pd4 = pd3 + par['P11'] * raw_P * raw_P * raw_P

    return po1 + po2 + pd4

def pressure_to_altitude(P_Pa, P0_Pa):
    return 44330.0 * (1.0 - (P_Pa / P0_Pa) ** (1.0 / 5.255))

def integrate(series, times):
    out = [0.0]
    for i in range(1, len(series)):
        dt = times[i] - times[i-1]
        out.append(out[-1] + (series[i] + series[i-1]) / 2 * dt)
    return out

# ---------------------------------------------------------------------------
G = 9.80665
SKIP = 54
START = 73875
STOP = 73935
BIAS_SAMPLES = 20

# ---------------------------------------------------------------------------
# Load data
# ---------------------------------------------------------------------------
x      = load_integers("AX.txt")[SKIP:][5*START:STOP*5]
y      = load_integers("AY.txt")[SKIP:][5*START:STOP*5]
z      = load_integers("AZ.txt")[SKIP:][5*START:STOP*5]
ts_raw = load_integers("TS.txt")[SKIP:][5*START:STOP*5]

P_raw  = load_hex_bmp("P_hex.txt", "P")[SKIP:][5*START:STOP*5]
T_raw  = load_hex_bmp("T_hex.txt", "T")[SKIP:][5*START:STOP*5]

par = parse_calibration(CAL_BYTES)

n = min(len(x), len(y), len(z), len(ts_raw), len(P_raw), len(T_raw))
t0 = ts_raw[0]
time = [(t - t0) / 1_000_000 for t in ts_raw[:n]]

x_g = [to_g(v) for v in x[:n]]
y_g = [to_g(v) for v in y[:n]]
z_g = [to_g(v) for v in z[:n]]

# ---------------------------------------------------------------------------
# BMP compensation
# ---------------------------------------------------------------------------
T_C  = [compensate_temperature(rt, par) for rt in T_raw[:n]]
P_Pa = [compensate_pressure(rp, t, par) for rp, t in zip(P_raw[:n], T_C)]

# Filter out garbage: any pressure outside 50000-110000 Pa is bogus
valid_mask  = [50000 < p < 110000 for p in P_Pa]
P_Pa_clean  = [p if v else float('nan') for p, v in zip(P_Pa, valid_mask)]

# P0 = sum(p for p, v in zip(P_Pa[:BIAS_SAMPLES], valid_mask[:BIAS_SAMPLES]) if v) / \
#      max(sum(valid_mask[:BIAS_SAMPLES]), 1)
# Find the quietest 20-sample window before launch
# by looking for the period with lowest pressure variance
# (= most stable = on the pad, engine not yet firing)
SEARCH_WINDOW = 100  # samples to search through at start
best_var = float('inf')
best_start = 0
for i in range(SEARCH_WINDOW - BIAS_SAMPLES):
    window = P_Pa[i:i + BIAS_SAMPLES]
    valid = [p for p in window if 50000 < p < 110000]
    if len(valid) < BIAS_SAMPLES // 2:
        continue
    mean = sum(valid) / len(valid)
    var = sum((p - mean)**2 for p in valid) / len(valid)
    if var < best_var:
        best_var = var
        best_start = i

P0_samples = [p for p in P_Pa[best_start:best_start + BIAS_SAMPLES]
              if 50000 < p < 110000]
P0 = sum(P0_samples) / len(P0_samples)
print(f"P0 computed from samples {best_start}-{best_start + BIAS_SAMPLES} "
      f"(variance {best_var:.1f} Pa^2)")

print(f"Pad pressure  (first {BIAS_SAMPLES} samples mean): {P0:.1f} Pa")
print(f"Pad temp      (first {BIAS_SAMPLES} samples mean): "
      f"{sum(T_C[:BIAS_SAMPLES]) / BIAS_SAMPLES:.2f} C")

altitude = [pressure_to_altitude(p, P0) if not (p != p) else float('nan')
            for p in P_Pa_clean]

# ---------------------------------------------------------------------------
# IMU bias and integration
# ---------------------------------------------------------------------------
x_bias = sum(x_g[:BIAS_SAMPLES]) / BIAS_SAMPLES
y_bias = sum(y_g[:BIAS_SAMPLES]) / BIAS_SAMPLES
z_bias = sum(z_g[:BIAS_SAMPLES]) / BIAS_SAMPLES

print(f'\nPad bias (first {BIAS_SAMPLES} samples):')
print(f'  X: {x_bias:+.3f} g')
print(f'  Y: {y_bias:+.3f} g')
print(f'  Z: {z_bias:+.3f} g')
print(f'  Total magnitude: {(x_bias**2 + y_bias**2 + z_bias**2)**0.5:.3f} g')

ax_ms2 = [(a - x_bias) * G for a in x_g]
ay_ms2 = [(a - y_bias) * G for a in y_g]
az_ms2 = [(a - z_bias) * G for a in z_g]

vx = integrate(ax_ms2, time)
vy = integrate(ay_ms2, time)
vz = integrate(az_ms2, time)

px = integrate(vx, time)
py = integrate(vy, time)
pz = integrate(vz, time)

# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------
# fig, (ax1, ax2, ax3, ax4, ax5) = plt.subplots(5, 1, figsize=(12, 17), sharex=True)
fig, (ax4, ax5, ax1) = plt.subplots(3, 1, figsize=(12, 17), sharex=True)

ax1.plot(time, x_g, label='X')
ax1.plot(time, y_g, label='Y')
ax1.plot(time, z_g, label='Z')
ax1.set_ylabel('Acceleration (g)')
ax1.set_title('Accel Axes (raw)')
ax1.legend(); ax1.grid(True)

# ax2.plot(time, vx, label=f'Vx ({min(vx):.1f} / {max(vx):.1f} m/s)')
# ax2.plot(time, vy, label=f'Vy ({min(vy):.1f} / {max(vy):.1f} m/s)')
# ax2.plot(time, vz, label=f'Vz ({min(vz):.1f} / {max(vz):.1f} m/s)')
# ax2.set_ylabel('Velocity (m/s)')
# ax2.set_title('Velocity by Axis (pad bias subtracted)')
# ax2.legend(); ax2.grid(True)

# ax3.plot(time, px, label=f'Px ({min(px):.1f} / {max(px):.1f} m)')
# ax3.plot(time, py, label=f'Py ({min(py):.1f} / {max(py):.1f} m)')
# ax3.plot(time, pz, label=f'Pz ({min(pz):.1f} / {max(pz):.1f} m)')
# ax3.set_ylabel('Position (m)')
# ax3.set_title('Position by Axis (double integrated)')
# ax3.legend(); ax3.grid(True)

# Barometric vertical velocity: finite difference of altitude over time.
# nan propagates naturally where altitude is nan (garbage samples).
baro_vz = [float('nan')]  # no velocity for first sample
for i in range(1, len(altitude)):
    a0, a1 = altitude[i-1], altitude[i]
    dt = time[i] - time[i-1]
    if dt > 0 and a0 == a0 and a1 == a1:  # both non-nan and valid dt
        baro_vz.append((a1 - a0) / dt)
    else:
        baro_vz.append(float('nan'))

valid_alt = [a for a in altitude if a == a]
peak = max(valid_alt) if valid_alt else 0.0
valid_baro_vz = [v for v in baro_vz if v == v]
peak_baro_vz = max(valid_baro_vz) if valid_baro_vz else 0.0

ax4.plot(time, altitude, label=f'Baro altitude (peak {peak:.1f} m)', color='C3')
ax4.set_ylabel('Altitude AGL (m)')
ax4.set_title('Barometric Altitude (relative to pad)')
ax4.legend(); ax4.grid(True)

ax5.plot(time, baro_vz, label=f'Baro Vz (peak {peak_baro_vz:.1f} m/s)', color='C4')
ax5.set_ylabel('Vertical velocity (m/s)')
ax5.set_xlabel('Time (s)')
ax5.set_title('Barometric Vertical Velocity (finite difference of altitude)')
ax5.legend(); ax5.grid(True)

plt.tight_layout()
plt.savefig(os.path.join(os.path.dirname(__file__), "flight_plot.png"), dpi=150)
print(f"Plot saved. Peak baro altitude: {peak:.1f} m, peak baro Vz: {peak_baro_vz:.1f} m/s")