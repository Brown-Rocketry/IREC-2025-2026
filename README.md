# Brown Rocketry — IREC 2025-2026 Payload Avionics

**Team:** Brown Rocketry  
**Rocket Name:** Providentia  
**Competition:** IREC 2025-2026 — 10K COTS Category (cancelled)

---

## Overview

This repository contains the avionics and payload data acquisition system developed for Brown University's IREC 2025-2026 entry. The rocket, Providentia, was a dual-deployment vehicle targeting 10,000 feet AGL, carrying a 3U CubeSat payload housing a sealed micro-terrarium experiment intended to assess the effects of short-term thermal, vibrational, and shock stresses on an enclosed micro-ecosystem during high-power rocket flight.

IREC 2026 was cancelled before the competition could take place. The payload firmware reached a state of full sensor integration and flash datalogging prior to cancellation, and the system had not yet undergone a flight test. This repository serves as a record of the technical work completed during the 2025-2026 development cycle.

---

## Team

- **Student Lead:** Ethan Kim
- **Faculty Advisor:** Daniel Harris  
- **Team Mentor:** Peter Tarle (TRA L3, #18555)  
- **Payload & Avionics Engineer:** Margeaux Corrigan (margeaux_corrigan@brown.edu)

---

## Vehicle Specifications

| Parameter | Value |
|---|---|
| Length | 2.26 m |
| Diameter | 157 mm |
| Liftoff Weight | 22.86 kg (with motor) |
| Payload Weight | 4.1 kg |
| Motor | Aerotech M1800FJ-4 (8207.7 N-s total impulse) |
| Target Apogee | 10,000 ft AGL |
| Predicted Apogee | 10,413 ft AGL |
| Max Velocity | 311 m/s |
| Max Acceleration | 12.44 G |

---

## Payload Avionics System

### Hardware

The payload data acquisition system runs on a **Raspberry Pi Pico (RP2040)**, programmed in Ada using the `light-cortex-m0p` bare-metal runtime. All sensors communicate over I2C (GP0/GP1). SPI flash uses GP16–GP19. UART debug output is available on GP8/GP9 (UART1) at 115200 baud.

| Component | Part | Interface |
|---|---|---|
| Microcontroller | Raspberry Pi Pico H (RP2040) | — |
| IMU | ST LSM9DS1 (accel / gyro / mag) | I2C |
| Barometric Sensor | Bosch BMP390 (Adafruit breakout) | I2C |
| Flash Storage | Winbond W25Q128 (Adafruit 5634 breakout) | SPI |
| Power | 3× AA batteries in series → VSYS | — |

A humidity sensor (SHT30) was evaluated but deferred due to time constraints.

### Firmware

The flight firmware is written entirely in Ada, built with [Alire](https://alire.ada.dev/) using the `rp2040_hal` crate (v2.7.0, JeremyGrosser). It is flashed via OpenOCD with a CMSIS-DAP debug probe.

**Status at time of cancellation:**
- All nine LSM9DS1 axes (accelerometer, gyroscope, magnetometer) confirmed working with live signed data
- BMP390 raw pressure and temperature confirmed working
- W25Q128 SPI flash confirmed working with verified erase/write/readback cycle
- Unified `flight_logger.adb` combining all sensors with flash datalogging written and compiling
- Flash readback/dump utility in progress
- System not flight-tested

### Data Format

Each logged sample is 28 bytes, fitting 9 samples per 256-byte flash page (4 bytes reserved for a page sequence number):

| Field | Size | Description |
|---|---|---|
| Timestamp | 4 bytes | Microseconds since boot (`TIMERAWL`) |
| Accel X/Y/Z | 6 bytes | Signed 16-bit raw ADC values |
| Gyro X/Y/Z | 6 bytes | Signed 16-bit raw ADC values |
| Mag X/Y/Z | 6 bytes | Signed 16-bit raw ADC values |
| Pressure | 3 bytes | BMP390 raw 24-bit value |
| Temperature | 3 bytes | BMP390 raw 24-bit value |

### STM32 Development Material

This repository also contains exploratory development material for the **STM32 Nucleo-G431KB**, used for learning and prototyping in the Ada/AdaCore embedded ecosystem. This work was not directly tied to the flight payload system and is not flight-ready.

---

## Development History

Early-cycle prototyping used Arduino (Uno R3) with standard Adafruit sensor libraries as a proof-of-concept for sensor integration and data logging. This work, done during initial team formation, established the sensor suite and data requirements before the architecture shifted.

The final implementation moved away from Arduino/Adafruit entirely in favor of bare-metal Ada on the RP2040, with direct SVD register access for timing and SPI communication. This reflects a significant increase in technical depth relative to the original plan, trading higher-level convenience for a more precise understanding of the hardware.

---

## Build & Flash

### Prerequisites

- [Alire](https://alire.ada.dev/) package manager
- OpenOCD with CMSIS-DAP support
- GNAT Ada toolchain (via Alire)

### Build

```bash
alr build
```

### Flash

```bash
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 5000" \
  -c "program bin/flight_logger.elf verify reset exit"
```

### Debug Output

```bash
screen /dev/ttyUSBx 115200
```

---

## Key Hardware Notes

A number of non-obvious hardware behaviors were encountered and resolved during development. These are documented here for anyone working with similar hardware in future cycles.

- **I2C addressing:** The `rp2040_hal` HAL shifts addresses right by 1 internally; always pass 8-bit addresses (BMP390 = `0xEE` when SDO pulled high, LSM9DS1 accel/gyro = `0xD6`, mag = `0x3C`)
- **GPIO configuration:** `Schmitt => True` is required on both SDA and SCL or the I2C bus will not drive
- **SPI reads:** The HAL's `Receive` does not generate clock cycles; correct approach uses a `Transfer` procedure via direct `RP2040_SVD.SPI` register access, writing and reading one byte at a time in lockstep
- **SPI Mode 0:** `Active_Low` is correct in `rp2040_hal` for CPOL=0 — the enum names the idle state
- **Runtime:** Use `light-cortex-m0p`, not `light_tasking_rp2040` — the tasking runtime is incompatible with UART output
- **`Integer_16'Image`:** Hangs on the bare-metal runtime; cast through `Integer_32` or handle manually via `Unsigned_16`
- **UART output:** Bulk `Transmit` calls drop bytes; transmit one byte at a time with a short delay between calls
- **Timestamp:** `RP.Device.Timer.Clock` does not exist; use `RP2040_SVD.TIMER.TIMER_Periph.TIMERAWL` directly
- **I2C pin mapping:** GP0/GP1 with `I2CM_0` works reliably; GP2–GP5 cause `Configure` to hang; GP6/GP7 on `I2CM_1` returns `ERR_ERROR` on an empty bus

---

## Repository Structure

```
/
├── pico_uart_demo/      # Early UART bringup and demo
├── terrarium/           # STM32/AdaCore exploration and development material
│   └── src/
│       ├── svd/
│       ├── blinky.adb
│       ├── blinky_0.adb
│       └── terrarium.adb
├── terrarium_pico/      # Main RP2040 payload firmware (Ada)
│   └── src/
│       ├── flight_logger.adb   # Unified sensor + flash datalogging
│       ├── i2c_sensors.adb     # LSM9DS1 and BMP390 drivers
│       ├── spi_flash_test.adb  # W25Q128 erase/write/readback verification
│       ├── i2c_demo.adb        # I2C bringup demo
│       ├── blinky_demo.adb     # Basic bringup
│       ├── uart_echo.adb       # UART bringup demo
│       └── main.adb
└── README.md
```

---

## Acknowledgments

- **Peter Tarle** for mentorship and launch operations oversight
- **Olivier Henley** for embedded systems guidance and rocket integration oversight
- **RIMRA** (Rhode Island Model Rocketry Association) for launch site access
- **Pathways to Diversity Fund** and **Hazeltine Engineering Grant** for financial support
- **ESRA** for hosting IREC

---

## Contact

- **Website:** https://sites.google.com/brown.edu/brown-rocketry/home  
- **Instagram:** @brownrocketry  
- **Email:** ethan_m_kim@brown.edu

---

*Go Bears! 🐻🚀*
