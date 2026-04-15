# terrarium_pico — RP2040 Payload Firmware

Bare-metal Ada firmware for the Brown Rocketry IREC 2025-2026 payload data acquisition system. Runs on a Raspberry Pi Pico (RP2040), polling an IMU, barometric sensor, and writing packed binary samples to SPI flash.

See the [top-level README](../README.md) for project context, vehicle specs, and team information.

---

## Hardware

| Component | Part | Interface | Address / Pins |
|---|---|---|---|
| Microcontroller | [Raspberry Pi Pico H (RP2040)](https://pip-assets.raspberrypi.com/categories/610-raspberry-pi-pico/documents/RP-008307-DS-1-pico-datasheet.pdf?disposition=inline) | — | — |
| IMU | [ST LSM9DS1](https://www.st.com/resource/en/datasheet/lsm9ds1.pdf) (accel / gyro / mag) | I2C | AG: `0xD6`, Mag: `0x3C` |
| Barometric Sensor | [Bosch BMP390](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmp390-ds002.pdf) (Adafruit breakout) | I2C | `0xEE` (SDO pulled high) |
| Flash Storage | [Winbond W25Q128](https://www.winbond.com/resource-files/w25q128jv%20revf%2003272018%20plus.pdf) ([Adafruit 5634 breakout](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5045/5634_Web.pdf)) | SPI | CS: GP17 |

### Pin Assignments

| Function | GPIO |
|---|---|
| I2C SDA | GP0 |
| I2C SCL | GP1 |
| UART TX | GP8 |
| UART RX | GP9 |
| SPI MISO | GP16 |
| SPI CS (manual GPIO) | GP17 |
| SPI SCK | GP18 |
| SPI MOSI | GP19 |

Legend: `[*]` used now, `[P]` required power/ground, `[R]` reserved/non-GPIO, `[ ]` free.

```text
Pico / Pico H (RP2040) — full layout for this firmware
                         ┌──────────[USB]──────────┐
[*] GP0  (I2C SDA)   1 ──┤                         ├── 40 VBUS      [ ] USB 5V board power path
[*] GP1  (I2C SCL)   2 ──┤                         ├── 39 VSYS      [ ] External board power input (alternative)
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

SWD pads (Pico H): SWCLK / SWDIO / GND (optional for OpenOCD programming/debug)
```

```text
Required wiring (practical checklist)

Power:
  Pico 3V3_OUT -----------------------> LSM9DS1 VCC, BMP390 VCC/VIN, W25Q128 VCC/VIN
  Pico GND ---------------------------> LSM9DS1 GND, BMP390 GND, W25Q128 GND
  Pico board supply ------------------> either USB (VBUS path) OR external VSYS

I2C shared bus (both sensors on same wires):
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

Pins normally left alone in this build: `RUN`, `3V3_EN`, `ADC_VREF`, `AGND`.
---

## Firmware Overview

All firmware is written in Ada using the [`light-cortex-m0p`](https://alire.ada.dev/) bare-metal runtime, built with [Alire](https://alire.ada.dev/) and the [`rp2040_hal`](https://github.com/JeremyGrosser/pico_examples) crate (v2.7.0, JeremyGrosser). There are no tasks or protected objects — the architecture is a simple sequential polling loop.

### Source Files

| File | Description |
|---|---|
| `flight_logger.adb` | Main flight firmware — sensor polling, sample packing, flash datalogging |
| `i2c_sensors.adb` | Standalone sensor read verification for LSM9DS1 and BMP390 |
| `spi_flash_test.adb` | W25Q128 bringup — JEDEC ID, sector erase, page write, readback |
| `i2c_demo.adb` | Early I2C bringup and WHO_AM_I verification |
| `uart_echo.adb` | UART bringup demo |
| `blinky_demo.adb` | Basic LED blink, used for initial toolchain verification |
| `main.adb` | Minimal entry point stub |

The `.gpr` project file points to `flight_logger.adb` as the main entry point for flight builds.

---

## Data Format

Each sample is 28 bytes. Nine samples are packed into a 256-byte flash page, with the final 4 bytes used as a page sequence number.

### Sample Layout (28 bytes)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0–3 | 4 bytes | Timestamp | Microseconds since boot, `Unsigned_32`, LSB first |
| 4–5 | 2 bytes | Accel X | Signed 16-bit raw ADC, LSB first |
| 6–7 | 2 bytes | Accel Y | |
| 8–9 | 2 bytes | Accel Z | |
| 10–11 | 2 bytes | Gyro X | |
| 12–13 | 2 bytes | Gyro Y | |
| 14–15 | 2 bytes | Gyro Z | |
| 16–17 | 2 bytes | Mag X | |
| 18–19 | 2 bytes | Mag Y | |
| 20–21 | 2 bytes | Mag Z | |
| 22–24 | 3 bytes | Pressure | BMP390 raw 24-bit, LSB first |
| 25–27 | 3 bytes | Temperature | BMP390 raw 24-bit, LSB first |

### Page Layout (256 bytes)

```
Bytes   0–251  : 9 × 28-byte samples  (252 bytes)
Bytes 252–255  : Page sequence number (Unsigned_32, LSB first)
```

All IMU and BMP390 values are raw ADC output — no compensation or scaling is applied. BMP390 temperature and pressure can be converted to physical units post-flight using the factory calibration coefficients stored in the chip's NVM (see datasheet Section 8.4).

The timestamp uses `RP2040_SVD.TIMER.TIMER_Periph.TIMERAWL` (the lower 32 bits of the RP2040 hardware microsecond counter). It wraps approximately every 71 minutes.

---

## Flash Geometry

The W25Q128 is 16 MB, organized as 65,536 pages of 256 bytes, grouped into 4,096 sectors of 4 KB (16 pages). The firmware erases one sector at a time on demand as the write pointer advances, and performs an initial erase of sector 0 at boot. Flash is always written from address 0 and logging halts when the chip is full.

At 10 Hz (100 ms polling interval) the chip holds approximately **18.2 hours** of flight data.

---

## Build & Flash

### Prerequisites

- [Alire](https://alire.ada.dev/) package manager
- OpenOCD with CMSIS-DAP support
- A **Pico Probe** (or Raspberry Pi Debug Probe) for SWD programming/debugging
- GNAT Ada ARM cross-compiler (fetched automatically via Alire)

### Programming / Debug Wiring (Pico Probe + OpenOCD)

Use the white-ish female SWD cable from the probe kit to connect the probe to the target board.

Connect these three signals:

| Pico Probe side | Target Pico H side | Notes |
|---|---|---|
| SWCLK | SWCLK pad/pin | Clock line |
| SWDIO | SWDIO pad/pin | Data line |
| GND | GND | Mandatory common ground |

If you are using a second Pico flashed as `picoprobe`, its SWD pins are typically:

- `GP2` = SWCLK
- `GP3` = SWDIO
- `GND` = GND

On the target Pico H, use the SWD pads (`SWCLK`, `SWDIO`) plus any nearby ground.
This is the connection used by the OpenOCD command below.

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

The `-c "adapter speed 5000"` flag is important — without it OpenOCD defaults to 100 kHz and flashing is extremely slow.

### Debug Output

Connect a serial terminal at 115200 baud on GP8/GP9 (UART1).

Recommended UART wire mapping (common black/yellow/orange USB-UART harness):

- **Black**  `GND`
- **Yellow** (adapter RX)  `GP8` (Pico TX)
- **Orange** (adapter TX)  `GP9` (Pico RX)

If your adapter uses a different color convention, follow the signal names (`TX`, `RX`, `GND`) rather than color.

Then open the terminal:

```bash
screen /dev/ttyUSBx 115200
```

On boot you should see:

```
--- Flight Logger Boot ---
I2C ready
SPI ready
JEDEC: 239 64 24
Erasing sector 0...
Ready to log
Sensors enabled
```

Each page flush logs its address:
```
Page 0 written at 0
Page 1 written at 256
...
```

---

## Key Hardware Notes

These are non-obvious behaviors encountered during development that are worth knowing if you touch this code.

- **I2C addressing:** `rp2040_hal` right-shifts addresses internally — always pass the 8-bit form (e.g. `0xD6`, not `0x6B`)
- **GPIO configuration:** `Schmitt => True` is required on both SDA and SCL or the I2C bus will not drive at all
- **I2C pin mapping:** GP0/GP1 with `I2CM_0` is the only reliable configuration tested; GP2–GP5 cause `Configure` to hang indefinitely
- **SPI reads:** The HAL's `Receive` does not generate clock cycles — use the `Transfer` procedure (in `flight_logger.adb`) which writes and reads one byte at a time via direct `RP2040_SVD.SPI` register access
- **SPI polarity:** `Active_Low` in `rp2040_hal` means CPOL=0 (clock idles low) — the name refers to the idle state, not the active state
- **WIP polling:** Sector erase takes ~400 ms — the `Wait_Until_Ready` loop must run long enough or a subsequent write will corrupt data
- **`Integer_16'Image`:** Hangs on the bare-metal runtime — cast through `Integer_32` before printing
- **UART output:** Bulk `Transmit` drops bytes under rapid succession — `Put_Line` transmits the whole buffer in one call followed by a busy-wait loop; tune the loop count if bytes are still dropped
- **Runtime:** Use `light-cortex-m0p` — `light_tasking_rp2040` is incompatible with UART output

---

## References

- [Alire package manager](https://alire.ada.dev/)
- [JeremyGrosser/pico_examples](https://github.com/JeremyGrosser/pico_examples) — HAL usage examples
- [pico-doc.synack.me](https://pico-doc.synack.me/) — community RP2040 Ada documentation
- [LSM9DS1 datasheet](https://www.st.com/resource/en/datasheet/lsm9ds1.pdf)
- [BMP390 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmp390-ds002.pdf)
- [W25Q128 datasheet](https://www.winbond.com/resource-files/w25q128jv%20revf%2003272018%20plus.pdf)
- [Adafruit 5634 breakout datasheet](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5045/5634_Web.pdf)
- [RP2040 Pico datasheet](https://pip-assets.raspberrypi.com/categories/610-raspberry-pi-pico/documents/RP-008307-DS-1-pico-datasheet.pdf?disposition=inline)
- [SHT3x datasheet](https://cdn-shop.adafruit.com/product-files/2857/Sensirion_Humidity_SHT3x_Datasheet_digital-767294.pdf) *(evaluated, not integrated)*
