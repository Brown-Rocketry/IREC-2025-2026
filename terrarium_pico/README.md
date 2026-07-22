# terrarium_pico: RP2040 Payload Flight Firmware

Bare-metal Ada firmware for the Brown Rocketry payload data acquisition system. Runs on a Raspberry Pi Pico (RP2040), polls a 9-axis IMU and a barometric sensor over a shared I2C bus, packs each reading into a fixed 28-byte record, and writes to SPI flash.

Flown on a high-power launch at a RIMRA field, [FILL: month/year]. Flight duration 45.2 seconds, against a configured ±16 g accelerometer range. The flash filled to capacity over a 1,497 minute campaign, 589,824 samples, recovered complete with no missing pages.

See the [top-level README](../README.md) for vehicle context, team, and program history.

---

## Hardware

| Component | Part | Interface | Address / Pins |
|---|---|---|---|
| Microcontroller | [Raspberry Pi Pico H (RP2040)](https://pip-assets.raspberrypi.com/categories/610-raspberry-pi-pico/documents/RP-008307-DS-1-pico-datasheet.pdf?disposition=inline) | | |
| IMU | [ST LSM9DS1](https://www.st.com/resource/en/datasheet/lsm9ds1.pdf), accel / gyro / mag | I2C | AG `0xD6`, Mag `0x3C` |
| Barometric sensor | [Bosch BMP390](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmp390-ds002.pdf), Adafruit breakout | I2C | `0xEE`, SDO pulled high |
| Flash storage | [Winbond W25Q128](https://www.winbond.com/resource-files/w25q128jv%20revf%2003272018%20plus.pdf), [Adafruit 5634 breakout](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5045/5634_Web.pdf) | SPI | CS GP17 |

### Pin assignments

| Function | GPIO |
|---|---|
| I2C SDA | GP0 |
| I2C SCL | GP1 |
| UART TX | GP8 |
| UART RX | GP9 |
| SPI MISO | GP16 |
| SPI CS, manual GPIO | GP17 |
| SPI SCK | GP18 |
| SPI MOSI | GP19 |

Legend: `[*]` used, `[P]` power/ground, `[R]` reserved/non-GPIO, `[ ]` free.

```text
Pico / Pico H (RP2040), full layout for this firmware
                         ┌──────────[USB]──────────┐
[*] GP0  (I2C SDA)   1 ──┤                         ├── 40 VBUS      [ ] USB 5V board power path
[*] GP1  (I2C SCL)   2 ──┤                         ├── 39 VSYS      [ ] External board power input
[P] GND              3 ──┤                         ├── 38 GND       [P] Common ground
[ ] GP2              4 ──┤                         ├── 37 3V3_EN    [ ] Regulator enable (leave high/open)
[ ] GP3              5 ──┤                         ├── 36 3V3_OUT   [P] 3.3V rail to sensors + flash
[ ] GP4              6 ──┤                         ├── 35 ADC_VREF  [R] Analog reference (unused)
[ ] GP5              7 ──┤                         ├── 34 GP28/ADC2 [ ] Free GPIO/ADC
[P] GND              8 ──┤                         ├── 33 AGND      [R] Analog ground (unused)
[ ] GP6              9 ──┤                         ├── 32 GP27/ADC1 [ ] Free GPIO/ADC
[ ] GP7             10 ──┤                         ├── 31 GP26/ADC0 [ ] Free GPIO/ADC
[*] GP8  (UART TX)  11 ──┤                         ├── 30 RUN       [R] Reset control (optional)
[*] GP9  (UART RX)  12 ──┤                         ├── 29 GP22      [ ] Free GPIO
[P] GND             13 ──┤                         ├── 28 GND       [P] Extra ground point
[ ] GP10            14 ──┤                         ├── 27 GP21      [ ] Free GPIO
[ ] GP11            15 ──┤                         ├── 26 GP20      [ ] Free GPIO
[ ] GP12            16 ──┤                         ├── 25 GP19      [*] SPI MOSI -> flash DI - IO1
[ ] GP13            17 ──┤                         ├── 24 GP18      [*] SPI SCK  -> flash CLK
[P] GND             18 ──┤                         ├── 23 GND       [P] Recommended flash ground
[ ] GP14            19 ──┤                         ├── 22 GP17      [*] SPI CS   -> flash CS
[ ] GP15            20 ──┤                         ├── 21 GP16      [*] SPI MISO -> flash DO - IO0
                         └─────────────────────────┘

SWD pads (Pico H): SWCLK / SWDIO / GND, used for OpenOCD programming and debug
```

```text
Required wiring

Power:
  Pico 3V3_OUT -----------------------> LSM9DS1 VCC, BMP390 VCC/VIN, W25Q128 VCC/VIN
  Pico GND ---------------------------> LSM9DS1 GND, BMP390 GND, W25Q128 GND
  Pico board supply ------------------> USB (VBUS path) OR external VSYS

I2C shared bus (both sensors on the same wires):
  GP0 (SDA) --------------------------> LSM9DS1 SDA + BMP390 SDA
  GP1 (SCL) --------------------------> LSM9DS1 SCL + BMP390 SCL

SPI flash:
  GP16 (MISO) ------------------------> W25Q128 DO
  GP19 (MOSI) ------------------------> W25Q128 DI
  GP18 (SCK)  ------------------------> W25Q128 CLK
  GP17 (CS)   ------------------------> W25Q128 CS

Optional UART debug:
  GP8 (TX) ---------------------------> USB-UART RX
  GP9 (RX) <--------------------------- USB-UART TX
  GND -------------------------------- USB-UART GND
```

Pins deliberately left alone in this build: `RUN`, `3V3_EN`, `ADC_VREF`, `AGND`.

Both sensors share a single I2C bus because their addresses do not collide (`0xD6`, `0x3C`, `0xEE`) and the combined bandwidth at the logging rate is a small fraction of standard-mode capacity. That saved two pins and, more usefully, one bus to bring up and debug.

---

## Firmware overview

All firmware is Ada on the [`light-cortex-m0p`](https://alire.ada.dev/) bare-metal runtime, built with [Alire](https://alire.ada.dev/) against the [`rp2040_hal`](https://github.com/JeremyGrosser/pico_examples) crate (v2.7.0, JeremyGrosser). There are no tasks and no protected objects. The architecture is a sequential polling loop.

That was chosen on purpose. For a flight window measured in seconds, a single loop with no scheduler means the timing is readable straight off the source, there is no preemption to reason about, and there is no concurrency failure mode that only appears under vibration.

### HAL versus register-level access

The two buses are driven differently, and the difference is the most useful thing in this repository.

**I2C uses the `rp2040_hal` crate.** It worked, the sensor bus was not the schedule risk, and launch was fixed. This was a deadline decision and it is worth naming as one.

**SPI uses direct `RP2040_SVD.SPI` register access.** It had to. The HAL's `Receive` does not generate clock cycles, so flash reads return nothing at all. Recovering data meant writing a `Transfer` procedure that drives the peripheral registers directly, clocking one byte out and one byte in per iteration. Timestamping is also register-level, reading `TIMER_Periph.TIMERAWL` directly because the crate has no working clock source at this version.

Having written both against the same chip in the same project, the tradeoff stopped being abstract: the HAL is a fine place to start and an unreliable place to stay when you need to know exactly what the peripheral is doing. That is what the follow-on [no-HAL C driver stack](https://github.com/MargXX/Bare-Metal-Drivers) is for.

### Source files

| File | Description |
|---|---|
| `flight_logger.adb` | Flight firmware: sensor polling, sample packing, flash datalogging |
| `i2c_sensors.adb` | Standalone LSM9DS1 and BMP390 read verification |
| `spi_flash_test.adb` | W25Q128 bringup: JEDEC ID, sector erase, page write, readback |
| `i2c_demo.adb` | Early I2C bringup and WHO_AM_I verification |
| `uart_echo.adb` | UART bringup demo |
| `blinky_demo.adb` | LED blink, initial toolchain verification |
| `main.adb` | Minimal entry point stub |

The `.gpr` file sets `flight_logger.adb` as the main entry point for flight builds.

---

## Sensor configuration

Logged values are raw ADC output, so these settings are required to convert a recovered log to physical units. They are recorded here because the flight log does not carry them.

### Written by the firmware

| Register | Value | Meaning |
|---|---|---|
| `CTRL_REG6_XL` (0x20) | `0b01101000` | Accel ODR 119 Hz, full scale ±16 g |
| `CTRL_REG1_G` (0x10) | `0b01111000` | Gyro ODR 119 Hz, full scale ±2000 dps |
| `CTRL_REG1_M` (0x20) | `0b11110000` | Mag temperature compensation on, XY ultra-high performance, ODR 10 Hz |
| `CTRL_REG3_M` (0x22) | `0x00` | Mag continuous conversion mode, I2C enabled |
| `PWR_CTRL` (0x1B) | `0x33` | BMP390 pressure and temperature enabled, normal mode |

### Conversion factors

| Channel | Full scale | Scale factor |
|---|---|---|
| Accelerometer | ±16 g | 0.732 mg/LSB |
| Gyroscope | ±2000 dps | 70 mdps/LSB |
| Magnetometer | ±4 gauss (reset default) | 0.14 mgauss/LSB |

### Left at reset defaults

These registers are never written, so the parts run at their power-on defaults. Recorded because a recovered log cannot be interpreted without knowing this.

| Register | Default | Consequence |
|---|---|---|
| `CTRL_REG2_M` (0x21) | `0x00` | Magnetometer full scale is ±4 gauss |
| `CTRL_REG4_M` (0x23) | `0x00` | Magnetometer Z axis runs in low-power mode while XY runs ultra-high performance |
| BMP390 `OSR` (0x1C) | `0x02` | Pressure oversampling x4, temperature oversampling x1 |
| BMP390 `ODR` (0x1D) | `0x00` | Nominal 200 Hz output, 5 ms period |
| BMP390 `CONFIG` (0x1F) | `0x00` | IIR filter bypassed |

### Sampling

The sensors are configured far faster than the logger reads them. Accelerometer and gyroscope run at 119 Hz ODR, while the logging loop averaged **6.57 Hz** across the campaign and had fallen to **5 Hz** by the end. Every logged sample is therefore a fresh reading rather than a repeat, but the log is a decimated view of the available bandwidth, not the full signal.

| Measure | Value |
|---|---|
| Sensor output data rate | 119 Hz, accel and gyro |
| Mean logging rate | 6.57 Hz, derived from 589,824 samples over 1,497.39 minutes |
| Mean sample interval | 152.3 ms |
| Final logging rate | 5 Hz, 200 ms interval |
| Drift over the run | Interval grew about 31 percent from mean to final |

The loop has no fixed period. It issues four I2C transactions, packs a sample, flushes a page every ninth iteration, and then applies a flat 6 ms delay. Loop time is set by whatever the bus and the flash do, not by a deadline, which is why the achieved rate is well below the nominal target. This is survivable only because every sample carries its own hardware timestamp: the cadence varies, the record of when each reading was taken does not.

**On the peak acceleration measurement.** The accelerometer was configured at ±16 g and the highest single logged sample is 14.5 G, roughly 90 percent of full scale. The channel did not saturate, so that reading is a real measurement rather than a rail.

It is reported here but not treated as the flight's peak acceleration, because a single isolated sample at this rate cannot support that claim. The flight lasted 45.2 seconds, covered by roughly 230 to 300 logged samples depending on the loop rate at the time of launch, with only a handful spanning motor burn. A millisecond-scale event such as ejection charge firing is orders of magnitude shorter than the sample interval, so a lone spike is an aliased slice of a transient rather than a measurement of its magnitude. The figure quoted elsewhere for this flight is the sustained boost-phase acceleration of [FILL] G, which is supported by multiple consecutive samples.

The distinction is a limitation of the logging rate, not of the sensor. See [Known limitations](#known-limitations).

BMP390 pressure and temperature convert to physical units using the factory calibration coefficients in chip NVM, per datasheet section 8.4. No compensation is applied onboard.

---

## Data format

Each sample is 28 bytes. Nine samples fill a 256-byte flash page, and the final 4 bytes hold a page sequence number.

### Sample layout, 28 bytes

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0-3 | 4 | Timestamp | Microseconds since boot, `Unsigned_32`, LSB first |
| 4-5 | 2 | Accel X | Signed 16-bit raw ADC, LSB first |
| 6-7 | 2 | Accel Y | |
| 8-9 | 2 | Accel Z | |
| 10-11 | 2 | Gyro X | |
| 12-13 | 2 | Gyro Y | |
| 14-15 | 2 | Gyro Z | |
| 16-17 | 2 | Mag X | |
| 18-19 | 2 | Mag Y | |
| 20-21 | 2 | Mag Z | |
| 22-24 | 3 | Pressure | BMP390 raw 24-bit, LSB first |
| 25-27 | 3 | Temperature | BMP390 raw 24-bit, LSB first |

### Page layout, 256 bytes

```
Bytes   0-251  : 9 x 28-byte samples  (252 bytes)
Bytes 252-255  : Page sequence number (Unsigned_32, LSB first)
```

The page sequence number is the recovery mechanism. Flash pages carry no inherent ordering once read back as a flat image, and a partial or interrupted log has to be reassembled from whatever survived. Four bytes per page buys the ability to detect gaps and order what is there.

The timestamp reads the lower 32 bits of the RP2040 hardware microsecond counter (`TIMERAWL`). It wraps roughly every 71 minutes, so any log longer than that requires stitching wraps back together during post-processing. See [Known limitations](#known-limitations).

---

## Flash geometry

The W25Q128 is 16 MB: 65,536 pages of 256 bytes, in 4,096 sectors of 4 KB (16 pages each).

The firmware erases sector 0 at boot and then erases each subsequent sector on demand as the write pointer advances. Writing always starts at address 0, and logging halts when the chip is full rather than wrapping. Halting rather than wrapping is deliberate: on a system with one flight and one recovery, overwriting the earliest data is the worse failure.

Capacity is 65,536 pages at 9 samples per page, or **589,824 samples** total.

The flash filled completely across the flight and ground campaign, and the full image was recovered intact with no missing pages.

| Measure | Value |
|---|---|
| Total logged time | 1,497.39 minutes, 24.96 hours |
| Samples written | 589,824, full capacity |
| Mean logging rate | 6.57 Hz |
| Flight portion of the log | 45.2 s, about 0.05 percent of total |

Because logging halts rather than wraps, filling the chip means the campaign ended when storage ran out rather than when testing finished.

---

## Build and flash

### Prerequisites

- [Alire](https://alire.ada.dev/) package manager
- GNAT Ada ARM cross-compiler, fetched automatically by Alire
- OpenOCD with CMSIS-DAP support
- A Pico Probe or Raspberry Pi Debug Probe for SWD

### SWD wiring

| Pico Probe side | Target Pico H side | Notes |
|---|---|---|
| SWCLK | SWCLK pad | Clock |
| SWDIO | SWDIO pad | Data |
| GND | GND | Mandatory common ground |

On a second Pico flashed as `picoprobe`, the SWD pins are `GP2` (SWCLK), `GP3` (SWDIO), and `GND`.

### Build

```bash
cd terrarium_pico
alr build
```

### Flash

```bash
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 5000" \
  -c "program bin/flight_logger.elf verify reset exit"
```

`adapter speed 5000` matters. Without it OpenOCD defaults to 100 kHz and flashing is extremely slow.

### Debug output

Serial terminal at 115200 baud on GP8/GP9 (UART1). Typical USB-UART harness mapping:

- **Black** to `GND`
- **Yellow**, adapter RX, to `GP8` (Pico TX)
- **Orange**, adapter TX, to `GP9` (Pico RX)

Follow the signal names rather than the colors if your adapter differs.

```bash
screen /dev/ttyUSBx 115200
```

Expected boot output:

```
--- Flight Logger Boot ---
I2C ready
SPI ready
JEDEC: 239 64 24
Erasing sector 0...
Ready to log
Sensors enabled
```

`JEDEC: 239 64 24` is `0xEF 0x40 0x18`: Winbond manufacturer ID, SPI flash type, 128 Mbit density. If this line reads all zeros or all `255`, the SPI wiring or chip select is wrong, and nothing downstream will work.

Each page flush logs its address:

```
Page 0 written at 0
Page 1 written at 256
...
```

---

## Key hardware notes

Non-obvious behaviors found during development. Each of these cost real debugging time.

- **I2C addressing.** `rp2040_hal` right-shifts addresses internally. Always pass the 8-bit form (`0xD6`, not `0x6B`).
- **GPIO configuration.** `Schmitt => True` is required on both SDA and SCL, or the I2C bus will not drive at all.
- **I2C pin mapping.** GP0/GP1 on `I2CM_0` is the only reliable configuration tested. GP2 through GP5 cause `Configure` to hang indefinitely.
- **SPI reads.** The HAL's `Receive` does not generate clock cycles. Use the `Transfer` procedure in `flight_logger.adb`, which writes and reads one byte at a time through direct `RP2040_SVD.SPI` register access.
- **SPI polarity.** `Active_Low` in `rp2040_hal` means CPOL=0, clock idles low. The name refers to the idle state, not the active state.
- **WIP polling.** Sector erase takes roughly 400 ms. The `Wait_Until_Ready` loop has to cover it, or the following write corrupts data.
- **`Integer_16'Image`.** Hangs on the bare-metal runtime. Cast through `Integer_32` before printing.
- **UART output.** Bulk `Transmit` drops bytes under rapid succession. `Put_Line` sends the whole buffer in one call followed by a busy-wait loop. Tune the loop count if bytes still drop.
- **Runtime selection.** Use `light-cortex-m0p`. `light_tasking_rp2040` is incompatible with UART output.

---

## Known limitations

Recorded honestly, so anyone reading a recovered log knows what to expect.

- **The logging rate cannot resolve the flight.** Roughly 6 Hz over a 45.2 second flight is a few hundred samples, and only a handful span motor burn. Shock events are orders of magnitude shorter than the 200 ms sample interval, so any single-sample spike is an aliased slice of a transient rather than a measurement of it. Capacity was never the constraint here: at 100 Hz the flash still holds well over an hour. The real limitation is that one continuous low-rate log was used for both the multi-hour ground campaign and the flight, when those two jobs want different rates.
- **The loop slowed over the run and nothing noticed.** The mean rate across the campaign was 6.57 Hz, but the final rate was 5 Hz, an interval increase of about 31 percent. Nothing in the firmware measures, reports, or records its own loop rate, so the drift is only visible by differencing timestamps after recovery. Logging a loop-time or health field per page would have surfaced it live. The cause is worth isolating, with I2C retry behavior under a draining 3xAA supply as the first hypothesis to test.
- **Magnetometer auto-increment depends on the HAL.** The LSM9DS1 magnetometer requires bit 7 of the sub-address to be asserted for multi-byte reads, and this code passes `OUT_X_L_M` as a plain `0x28`. Recovered flight data shows three independent axes, so `rp2040_hal`'s `Mem_Read` is evidently handling it. Anything porting this logic off the crate, including a register-level rewrite, has to set that bit explicitly.
- **Magnetometer Z axis is asymmetric with XY.** `CTRL_REG1_M` sets XY to ultra-high performance, but `CTRL_REG4_M` is never written, so Z stays in low-power mode. The three axes are not directly comparable in noise or resolution.
- **BMP390 timing is unmanaged.** Oversampling, output rate, and IIR filtering are all left at reset defaults, and there is no data-ready check before a read. At the x4 pressure and x1 temperature defaults, measurement time is longer than the 5 ms period implied by the default ODR setting, which is a combination the datasheet warns against. It is practically invisible at a 5 Hz poll rate, but the configuration should be set explicitly rather than inherited.
- **Timestamp wrap is not handled onboard.** `TIMERAWL` wraps about every 71 minutes. Across a log of this length that is roughly 20 to 27 wraps, all of which have to be reconstructed in post-processing. An epoch counter incremented on wrap detection would fix this for 4 bytes per page.
- **Total logged duration needs to be derived, not estimated.** The flash filled completely, so duration follows from 589,824 samples divided by the achieved rate. At the 5 Hz final rate that is 32.8 hours, not the 23 hours quoted elsewhere; the two reconcile only if the loop ran faster early in the campaign and degraded. The recovered log carries per-sample timestamps, so first sample to last sample, corrected for wraps, gives the exact figure. Publish that number.
- **The log is not self-describing.** Sensor full-scale ranges and output data rates exist only in source, not in the data. A configuration header page written at boot would make a recovered log interpretable on its own.
- **No flight-state marker.** Liftoff, burnout, and apogee are all inferred post-flight from the accelerometer trace. One state byte per sample would make segmentation trivial.
- **UART timing is calibrated, not checked.** The busy-wait loop after `Put_Line` is tuned empirically rather than gated on the UART FIFO status register. It works, and it is the wrong mechanism.
- **Logging halts when flash fills, and it did.** Halting rather than wrapping is correct for a single-flight recovery, but the chip reached capacity on this campaign. Any future flight requires a deliberate erase first, and there is currently no boot-time check or warning that the chip is already full.
- **The loop has no fixed period.** A flat 6 ms delay is appended to variable work, so cadence is set by bus and flash behavior rather than by a deadline. A timer-driven fixed-period loop would give a constant rate and remove the jitter. Per-sample hardware timestamps are what make the current design recoverable.
- **I2C is HAL-driven.** A schedule decision, documented above. The register-level rewrite lives in a [separate C driver stack](https://github.com/MargXX/Bare-Metal-Drivers).

---

## References

- [Alire package manager](https://alire.ada.dev/)
- [JeremyGrosser/pico_examples](https://github.com/JeremyGrosser/pico_examples), HAL usage examples
- [pico-doc.synack.me](https://pico-doc.synack.me/), community RP2040 Ada documentation
- [LSM9DS1 datasheet](https://www.st.com/resource/en/datasheet/lsm9ds1.pdf)
- [BMP390 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmp390-ds002.pdf)
- [W25Q128 datasheet](https://www.winbond.com/resource-files/w25q128jv%20revf%2003272018%20plus.pdf)
- [Adafruit 5634 breakout datasheet](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5045/5634_Web.pdf)
- [RP2040 Pico datasheet](https://pip-assets.raspberrypi.com/categories/610-raspberry-pi-pico/documents/RP-008307-DS-1-pico-datasheet.pdf?disposition=inline)
- [SHT3x datasheet](https://cdn-shop.adafruit.com/product-files/2857/Sensirion_Humidity_SHT3x_Datasheet_digital-767294.pdf), evaluated, not integrated