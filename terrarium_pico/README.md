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
- GNAT Ada ARM cross-compiler (fetched automatically via Alire)

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

Connect a serial terminal at 115200 baud on GP8/GP9 (UART1):

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