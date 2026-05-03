import os
import matplotlib.pyplot as plt

def load_integers(filename):
    path = os.path.join(os.path.dirname(__file__), filename)
    with open(path, 'r') as f:
        return [int(line.strip()) for line in f if line.strip()]

def to_g(raw, scale=16):
    return raw / (32768 / scale)

G = 9.80665  # m/s^2 per g
SKIP = 54
START = 73885
STOP = 73950
SAMPLE_RATE = 0.2  # seconds per sample at 5Hz
BIAS_SAMPLES = 20  # number of samples at start of window assumed to be pre-launch

x = load_integers("AX.txt")[SKIP:][5*START:STOP*5]
y = load_integers("AY.txt")[SKIP:][5*START:STOP*5]
z = load_integers("AZ.txt")[SKIP:][5*START:STOP*5]

n = min(len(x), len(y), len(z))
time = [t * SAMPLE_RATE for t in range(START*5, START*5 + n)]

x_g = [to_g(v) for v in x[:n]]
y_g = [to_g(v) for v in y[:n]]
z_g = [to_g(v) for v in z[:n]]

# measure pad bias from first BIAS_SAMPLES samples
x_bias = sum(x_g[:BIAS_SAMPLES]) / BIAS_SAMPLES
y_bias = sum(y_g[:BIAS_SAMPLES]) / BIAS_SAMPLES
z_bias = sum(z_g[:BIAS_SAMPLES]) / BIAS_SAMPLES
print(f'Pad bias (first {BIAS_SAMPLES} samples):')
print(f'  X: {x_bias:+.3f} g')
print(f'  Y: {y_bias:+.3f} g')
print(f'  Z: {z_bias:+.3f} g')
print(f'  Total magnitude: {(x_bias**2 + y_bias**2 + z_bias**2)**0.5:.3f} g (should be ~1.0)')

def integrate(series, dt):
    out = [0.0]
    for t in range(1, len(series)):
        out.append(out[-1] + (series[t] + series[t-1]) / 2 * dt)
    return out

# subtract pad bias, convert to m/s^2
ax_ms2 = [(a - x_bias) * G for a in x_g]
ay_ms2 = [(a - y_bias) * G for a in y_g]
az_ms2 = [(a - z_bias) * G for a in z_g]

vx = integrate(ax_ms2, SAMPLE_RATE)
vy = integrate(ay_ms2, SAMPLE_RATE)
vz = integrate(az_ms2, SAMPLE_RATE)

px = integrate(vx, SAMPLE_RATE)
py = integrate(vy, SAMPLE_RATE)
pz = integrate(vz, SAMPLE_RATE)

fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 11), sharex=True)

ax1.plot(time, x_g, label='X (flight axis)')
ax1.plot(time, y_g, label='Y')
ax1.plot(time, z_g, label='Z')
ax1.set_ylabel('Acceleration (g)')
ax1.set_title('Accel Axes (raw)')
ax1.legend()
ax1.grid(True)

ax2.plot(time, vx, label=f'Vx (peak {min(vx):.1f} / {max(vx):.1f} m/s)')
ax2.plot(time, vy, label=f'Vy (peak {min(vy):.1f} / {max(vy):.1f} m/s)')
ax2.plot(time, vz, label=f'Vz (peak {min(vz):.1f} / {max(vz):.1f} m/s)')
ax2.set_ylabel('Velocity (m/s)')
ax2.set_title('Velocity by Axis (pad bias subtracted)')
ax2.legend()
ax2.grid(True)

ax3.plot(time, px, label=f'Px (peak {min(px):.1f} / {max(px):.1f} m)')
ax3.plot(time, py, label=f'Py (peak {min(py):.1f} / {max(py):.1f} m)')
ax3.plot(time, pz, label=f'Pz (peak {min(pz):.1f} / {max(pz):.1f} m)')
ax3.set_ylabel('Position (m)')
ax3.set_xlabel('Time (s)')
ax3.set_title('Position by Axis (double integrated, pad bias subtracted)')
ax3.legend()
ax3.grid(True)

plt.tight_layout()
plt.show()