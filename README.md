# Brown Rocketry Payload Avionics (2025-2026)

**Team:** Brown Rocketry
**Vehicle:** Providentia
**Competition:** IREC 2025-2026, 10K COTS category. Entry accepted; competition cancelled before launch week.
**Flight status:** Payload flown and validated on a high-power launch at a RIMRA field, April 2026.

---

## Outcome

The payload data acquisition system was designed, built, and flown. Brown Rocketry's entry was accepted to IREC 2025-2026, and the competition was cancelled before launch week. Rather than shelve the payload, the avionics were integrated into a high-power vehicle and flown at a Rhode Island Model Rocketry Association launch.

Measured results from that flight and the surrounding ground campaign:

| Result | Value |
|---|---|
| Flight duration | 45.2 s |
| Sustained boost-phase acceleration | [FILL] G |
| Highest single logged sample | 14.5 G, treated as an unresolved transient, see note |
| Accelerometer configuration | ±16 g. No saturation at any point |
| Logging rate | 6.57 Hz mean, 5 Hz by end of run, against a 119 Hz sensor output rate |
| Flash at recovery | Full. 65,536 pages, 589,824 samples, 16 MB |
| Data integrity at recovery | Complete. No missing pages |
| Campaign duration, flight plus ground | 1,497.39 minutes, 24.96 hours |

All values above are read from the recovered flash log. Design and simulation figures are kept in a separate table below so the two are never confused.

**On the two acceleration figures.** The highest single sample in the log is 14.5 G, about 90 percent of the configured ±16 g range, so it is a real reading and not a saturated rail. It is not quoted as the flight's peak acceleration, because at 5 Hz a lone sample cannot support that. The flight ran 45.2 seconds, giving roughly 226 samples in total, and a shock event lasting milliseconds is far shorter than the 200 ms sample interval. The sustained boost-phase figure is the one backed by consecutive samples and the one used elsewhere.

**On campaign duration.** The flash filled to capacity, 589,824 samples over 1,497.39 minutes, which works out to a mean logging rate of 6.57 Hz. The loop had slowed to 5 Hz by the end of the run. Almost all of that time is ground testing: the flight itself is 45.2 seconds, about 0.05 percent of the log. The two figures are worth keeping separate, since one measures a flight and the other measures 25 hours of uninterrupted logging without a dropped page.

---

## Scope of my work

Brown Rocketry is a multi-subteam club. This repository covers the payload and avionics system only, and that system was mine end to end.

I was the sole developer of the payload avionics: sensor selection and integration, the electrical architecture and wiring, the power distribution, all flight firmware, hardware bring-up and debugging, and post-flight data recovery. Airframe, propulsion, recovery, and structures were other subteams' work and are not in this repository.

Where this README describes vehicle-level parameters, those come from the vehicle team's simulation and are labeled as such.

---

## Payload concept

Providentia carried a 3U CubeSat payload housing a sealed micro-terrarium, intended to assess the effects of short-duration thermal, vibrational, and shock loading on an enclosed micro-ecosystem during high-power flight. The avionics in this repository are the instrumentation for that experiment: a continuously logging inertial and barometric data acquisition system with onboard non-volatile storage.

---

## Vehicle specifications (design and simulation)

These are the vehicle team's design targets and simulation outputs for the IREC configuration. **None of these are measured values.**

| Parameter | Value | Source |
|---|---|---|
| Length | 2.26 m | Design |
| Diameter | 157 mm | Design |
| Liftoff weight | 22.86 kg with motor | Design |
| Payload weight | 4.1 kg | Design |
| Motor | Aerotech M1800FJ-4, 8207.7 N-s total impulse | Design |
| Target apogee | 10,000 ft AGL | Requirement |
| Predicted apogee | 10,413 ft AGL | Simulation |
| Predicted max velocity | 311 m/s | Simulation |
| Predicted max acceleration | 12.44 G | Simulation |

These describe Providentia as configured for IREC. The payload was later flown on a separate high-power vehicle at a RIMRA launch, and the flight results above come from that flight rather than from this configuration.

---

## Avionics system

### Hardware

The payload data acquisition system runs on a Raspberry Pi Pico (RP2040), programmed in Ada on the `light-cortex-m0p` bare-metal runtime. Both sensors share one I2C bus on GP0/GP1. Flash uses SPI on GP16 through GP19. UART debug output is on GP8/GP9 (UART1) at 115200 baud.

| Component | Part | Interface |
|---|---|---|
| Microcontroller | Raspberry Pi Pico H (RP2040) | |
| IMU | ST LSM9DS1, accel / gyro / mag | I2C |
| Barometric sensor | Bosch BMP390, Adafruit breakout | I2C |
| Flash storage | Winbond W25Q128, Adafruit 5634 breakout | SPI |
| Power | 3x AA in series to VSYS | |

An SHT30 humidity sensor was evaluated and deferred. It would have been the most directly relevant sensor to the terrarium experiment, and cutting it was a schedule decision rather than a technical one.

### Firmware

Flight firmware is written entirely in Ada, built with [Alire](https://alire.ada.dev/) against the `rp2040_hal` crate (v2.7.0, JeremyGrosser), and flashed over SWD with OpenOCD and a CMSIS-DAP probe. The architecture is a single sequential polling loop with no tasks or protected objects, chosen so that timing behavior stays inspectable and there is no scheduler to reason about during a 60 second flight.

Two peripherals are driven differently, deliberately:

- **I2C** goes through the `rp2040_hal` crate. The HAL worked, the deadline was real, and the sensor bus was not where the risk was.
- **SPI** is driven through direct `RP2040_SVD.SPI` register access. The HAL's `Receive` does not generate clock cycles on a read, so recovering data from flash required dropping below it. See [Key hardware notes](#key-hardware-notes).

That split is the honest picture of the project: use the abstraction where it holds, go to the register level where it does not. The register-level work here is what led into a [from-scratch driver stack in C](https://github.com/MargXX/Bare-Metal-Drivers) with no HAL at all.

See [`terrarium_pico/README.md`](terrarium_pico/README.md) for pin assignments, sensor configuration, data format, flash geometry, and full build instructions.

---

## Data format

Each sample is 28 bytes. Nine samples pack into a 256-byte flash page, with the last 4 bytes holding a page sequence number.

| Field | Size | Description |
|---|---|---|
| Timestamp | 4 bytes | Microseconds since boot, `TIMERAWL` |
| Accel X/Y/Z | 6 bytes | Signed 16-bit raw ADC |
| Gyro X/Y/Z | 6 bytes | Signed 16-bit raw ADC |
| Mag X/Y/Z | 6 bytes | Signed 16-bit raw ADC |
| Pressure | 3 bytes | BMP390 raw 24-bit |
| Temperature | 3 bytes | BMP390 raw 24-bit |

Values are logged raw, with no onboard compensation or scaling. Conversion to physical units happens post-flight using the BMP390 factory calibration coefficients read from chip NVM and the configured IMU full-scale ranges. Doing the math on the ground rather than in flight keeps the logging loop short and preserves the original ADC output for reanalysis.

---

## Development history

Early prototyping used an Arduino Uno R3 with Adafruit sensor libraries, as a proof of concept for the sensor suite and the data requirements during team formation.

The final implementation moved off Arduino and Adafruit entirely, to bare-metal Ada on the RP2040 with direct SVD register access for timing and SPI. That was a deliberate increase in scope: it traded library convenience for control over timing, bus behavior, and failure modes, and it made the system debuggable at the register level when the bus misbehaved.

---

## Key hardware notes

Non-obvious behaviors found and resolved during development. These cost real days, and they are recorded so the next cycle does not repay them.

- **I2C addressing.** `rp2040_hal` right-shifts addresses internally. Always pass the 8-bit form: BMP390 `0xEE` with SDO pulled high, LSM9DS1 accel/gyro `0xD6`, magnetometer `0x3C`.
- **GPIO configuration.** `Schmitt => True` is required on both SDA and SCL, or the I2C bus will not drive at all.
- **I2C pin mapping.** GP0/GP1 on `I2CM_0` is the only configuration that worked reliably. GP2 through GP5 cause `Configure` to hang indefinitely. GP6/GP7 on `I2CM_1` returns `ERR_ERROR` on an empty bus.
- **SPI reads.** The HAL's `Receive` does not generate clock cycles, so reads return nothing. The working approach is a `Transfer` procedure using direct `RP2040_SVD.SPI` register access, writing and reading one byte at a time in lockstep.
- **SPI polarity.** `Active_Low` in `rp2040_hal` corresponds to CPOL=0. The enum names the idle state, not the active state.
- **Erase timing.** Sector erase takes roughly 400 ms. The `Wait_Until_Ready` poll has to cover it or the following write corrupts data.
- **Runtime selection.** Use `light-cortex-m0p`. `light_tasking_rp2040` is incompatible with UART output.
- **`Integer_16'Image`.** Hangs on the bare-metal runtime. Cast through `Integer_32`, or handle manually as `Unsigned_16`.
- **UART output.** Bulk `Transmit` calls drop bytes under rapid succession. Transmit the buffer in one call followed by a busy-wait, and tune the loop count if bytes still drop.
- **Timestamp source.** `RP.Device.Timer.Clock` does not exist in this crate version. Use `RP2040_SVD.TIMER.TIMER_Periph.TIMERAWL` directly. It wraps roughly every 71 minutes, which matters for any log longer than that.

---

## What I would do differently

Written after the flight, not before it.

- **Log the flight faster than the ground campaign.** One continuous low-rate log served both a 25 hour endurance run and a 45.2 second flight. Those want different rates. Detecting liftoff and stepping up to a high rate for the flight window would have resolved the boost profile and the deployment transient, both of which are aliased at 5 Hz. Flash capacity was never the limiting factor.
- **Handle the 71-minute timestamp wrap in firmware.** `TIMERAWL` is 32 bits of microseconds. Across a log this long it wraps more than twenty times, and every wrap has to be stitched back together during post-processing instead of being resolved at the source. An epoch counter incremented on wrap detection would cost 4 bytes per page and remove the problem.
- **Give the loop a fixed period, and measure it.** A flat 6 ms delay appended to variable work means the sample rate is whatever the bus and flash leave behind. That is how a nominal design ended up averaging 6.57 Hz against sensors running at 119 Hz, and drifting to 5 Hz by the end of the run without anything in the system noticing. A timer-driven loop fixes the cadence; a logged loop-time field makes the drift visible while it is happening.
- **Log the sensor configuration to flash at boot.** Full-scale ranges and output data rates currently live only in source. Writing a header page with the configuration used means a recovered log is self-describing and the scaling factors cannot be guessed wrong months later.
- **Add a flight-state signal.** The log has no marker for liftoff, burnout, or apogee. Everything is inferred post-flight from the accelerometer trace. A single state byte per sample would make the data far easier to segment.
- **Replace the UART busy-wait.** Tuning a delay loop until bytes stop dropping works, but it is calibration against a symptom. Checking the UART FIFO status register is the actual fix.
- **Bring the I2C layer down to registers too.** SPI needed register-level access and got it. I2C got the HAL because the schedule said so. That is the right call under a launch deadline and the wrong one as a permanent state, which is why the follow-on work is a no-HAL driver stack.

---

## Repository structure

```
/
├── pico_uart_demo/      Early UART bringup and demo
├── terrarium/           STM32 Nucleo-G431KB exploration, not flight code
│   └── src/
│       ├── svd/
│       ├── blinky.adb
│       ├── blinky_0.adb
│       └── terrarium.adb
├── terrarium_pico/      Flight firmware (RP2040, Ada)
│   └── src/
│       ├── flight_logger.adb   Unified sensor polling and flash datalogging
│       ├── i2c_sensors.adb     LSM9DS1 and BMP390 read verification
│       ├── spi_flash_test.adb  W25Q128 erase / write / readback verification
│       ├── i2c_demo.adb        I2C bringup demo
│       ├── blinky_demo.adb     Toolchain verification
│       ├── uart_echo.adb       UART bringup demo
│       └── main.adb
└── README.md
```

`terrarium/` holds STM32 Nucleo-G431KB material from learning the Ada and AdaCore embedded toolchain. It is exploratory, it is not flight code, and it is not part of the payload system.

---

## Build and flash

### Prerequisites

- [Alire](https://alire.ada.dev/) package manager
- GNAT Ada ARM cross-compiler, fetched automatically by Alire
- OpenOCD with CMSIS-DAP support
- A Pico Probe or Raspberry Pi Debug Probe for SWD

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

Without `adapter speed 5000`, OpenOCD defaults to 100 kHz and flashing is extremely slow.

### Debug output

```bash
screen /dev/ttyUSBx 115200
```

Full wiring and expected boot output are in [`terrarium_pico/README.md`](terrarium_pico/README.md).

---

## Team

| Role | Name |
|---|---|
| Student lead | Ethan Kim |
| Faculty advisor | Daniel Harris |
| Team mentor | Peter Tarle, TRA L3 #18555 |
| Payload and avionics | Margeaux Corrigan |

## Acknowledgments

- **Peter Tarle** for mentorship and launch operations oversight
- **Olivier Henley** for embedded systems guidance and rocket integration oversight
- **RIMRA**, the Rhode Island Model Rocketry Association, for launch site access
- **Pathways to Diversity Fund** and **Hazeltine Engineering Grant** for financial support
- **ESRA** for hosting IREC

---

## Contact

Questions about the payload avionics or firmware in this repository:
**Margeaux Corrigan** · margeaux_corrigan@brown.edu · [margxx.github.io](https://margxx.github.io) · [github.com/MargXX](https://github.com/MargXX)

Brown Rocketry: [team site](https://sites.google.com/brown.edu/brown-rocketry/home) · [@brownrocketry](https://instagram.com/brownrocketry)