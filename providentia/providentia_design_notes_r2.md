# Providentia Avionics, Round 2: Design Notes

Working document for the Brown Rocketry payload avionics redesign and the port of the RP2040 (`terrarium_pico`) firmware to the STM32 Nucleo-G431KB GHAL crate chain. Captures the state of the discussion on 2026-10-21. Meant to be argued with, amended, and turned into crates one piece at a time.

Conventions used in this document:

- Hex values are written `0x..` in prose and tables. In Ada source they become `16#..#`.
- I2C addresses are always the 7-bit form. The Pico code used the 8-bit (shifted) form; the conversion table is in section 5.3.
- "Crate" means an Alire crate, which is a git repository with an `alire.toml` at its root.
- "Generic" means an Ada generic package. "`xyz_generic`" means a crate holding the generic interface for a class of device or bus.

## Glossary for people new to rockets or to this stack

| Term | Meaning |
|---|---|
| IMU | Inertial Measurement Unit. A chip with an accelerometer (measures acceleration, in g) and a gyroscope (measures rotation rate, in degrees per second). Some also have a magnetometer (compass). |
| Baro | Barometric pressure sensor. Air pressure drops with altitude, so pressure gives altitude. Also reports temperature. |
| g | Acceleration unit, 1 g is Earth gravity, about 9.81 m/s². A rocket under motor burn might see 10 to 20 g. An ejection charge is a shock of possibly 100 g or more for a few milliseconds. |
| dps | Degrees per second, the gyroscope unit. |
| ODR | Output Data Rate. How many times per second a sensor produces a new reading. |
| Full scale / range | The largest value a sensor can report. An accelerometer set to ±16 g reports garbage (clipped, "railed") above 16 g. |
| FIFO | First In First Out buffer inside a sensor. The sensor stores many readings itself, the microcontroller reads them in one burst later. |
| NOR flash | Non-volatile memory chip. Keeps data without power. Written in 256-byte pages, erased in 4 KB sectors. A page can only be written once between erases. |
| Page, sector | 256 bytes and 4096 bytes respectively on the W25Q128. Writing is per page, erasing is per sector (or bigger). |
| JEDEC ID | Three bytes a flash chip answers when asked who it is. Reading it is the first wiring test. |
| SPI, I2C, UART | The three wire protocols used here. SPI is fast and needs a chip select wire per device. I2C is slower, two wires shared by all devices, each device has an address. UART is the serial console. |
| CS | Chip Select. The wire that tells one SPI device "I am talking to you now". Low means selected. |
| Boost, coast, apogee, descent | Flight phases. Boost is motor burning. Coast is unpowered climb. Apogee is the highest point. Descent is under parachute. |
| Static port | A small hole in the airframe that lets the pressure inside the electronics bay equal the outside air pressure. Without it the baro reads wrong. |
| Alire | The Ada package manager. `alr build` fetches dependencies and builds. |
| GHAL | Generic Hardware Abstraction Layer. Olivier's bare-metal Ada stack built on Ada generics instead of tagged types. |

## 1. What exists today

### 1.1 The repository

`https://github.com/Brown-Rocketry/IREC-2025-2026`

| Directory | What it is | Status |
|---|---|---|
| `terrarium_pico/` | RP2040 (Raspberry Pi Pico) firmware that actually flew in April 2026. Depends on `pico_bsp` / `rp2040_hal`. | The code to port |
| `terrarium/` | An STM32G431 crate with a `null` main. Depends on `stm32g4_ghal`, which is the old crate name. | Delete or repoint to `stm32g431` |
| `pico_uart_demo/` | UART bring-up demo | Drop |
| `flash_data.txt`, `terrarium_pico/flight_data/` | Recovered flight log, per-channel text dumps, `fileprocess.py`, a plot | Keep as the reference dataset for testing |

### 1.2 The flown firmware, file by file

| File | Lines | What it does | Fate in the port |
|---|---|---|---|
| `flight_logger.adb` | 672 | The flight program. Brings up UART, SPI, I2C. Reads JEDEC ID. Configures LSM9DS1 (accel, gyro, mag) and BMP390. Scans flash for the first erased page so it can resume after a power cycle. Loops: timestamp, read accel, gyro, mag, baro over I2C, pack a 28-byte sample into a page buffer, every 9 samples write the page with a 4-byte sequence number, erase the next sector on demand, 6 ms delay. Halts when flash is full. | Split into chip crates, a journal generic, and a thin main |
| `flash_reader.adb` | 384 | Reads pages back until it finds a page whose sequence number is all 0xFF (never written). Prints samples in hex. | Merged into one `flash_dump` executable |
| `flash_reader_2.adb` | 462 | Same program, printing one decimal value per line for `fileprocess.py`. Unpacks pressure and temperature at byte offsets 23 and 26, while the logger packs them at 22 and 25. One side is wrong. | Merged into `flash_dump`; the offset bug disappears because writer and reader share one layout definition |
| `i2c_sensors.adb` | 231 | Configures and reads LSM9DS1 and BMP390 standalone, prints values | Becomes the chip crates' check executable |
| `spi_flash_test.adb` | 302 | W25Q128 bring-up: JEDEC ID, sector erase, page write, readback | Becomes the `w25q128` test executable |
| `i2c_demo.adb`, `uart_echo.adb`, `blinky_demo.adb`, `main.adb` | small | Early bring-up stubs | Drop |

Observations that drive the design:

- Every file is one monolithic procedure. `Put_Line`, `Transfer`, `CS_Low`, `CS_High`, the JEDEC read and `Read_Page` are copy-pasted four times. Where code is duplicated is exactly where a crate boundary belongs.
- SPI is driven by poking RP2040 registers directly because `rp2040_hal`'s `Receive` did not clock the bus. The Pico HAL was abandoned half way. The GHAL chain does not have this problem; `Spi_Interface.Read` clocks dummy bytes.
- The sample layout (offsets, sizes, endianness) exists in four places by hand (`Pack_U32`, `Unpack_U32` and friends). That is how the 22 vs 23 bug happened.

### 1.3 The flight data format that flew

Sample, 28 bytes, all little-endian (least significant byte first):

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | Timestamp | Microseconds since boot, lower 32 bits of the RP2040 `TIMERAWL` counter, wraps every 71 minutes |
| 4 | 2 | Accel X | Signed 16-bit raw ADC value |
| 6 | 2 | Accel Y | |
| 8 | 2 | Accel Z | |
| 10 | 2 | Gyro X | |
| 12 | 2 | Gyro Y | |
| 14 | 2 | Gyro Z | |
| 16 | 2 | Mag X | |
| 18 | 2 | Mag Y | |
| 20 | 2 | Mag Z | |
| 22 | 3 | Pressure | BMP390 raw 24-bit |
| 25 | 3 | Temperature | BMP390 raw 24-bit |

Page, 256 bytes: 9 samples (252 bytes) then a 4-byte page sequence number. A sequence number of 0xFFFFFFFF means the page was never written (flash erases to all ones).

Known problems recorded by the author in the README, all of which the redesign addresses:

- Logging rate was 6.57 Hz average, 5 Hz by the end, against a sensor rate of 119 Hz. A 45 second flight gave about 230 samples. Shock events were not resolved.
- One continuous log at one rate was used for 25 hours of ground testing and 45 seconds of flight. The flash filled with ground data.
- The loop slowed over the run and nothing noticed. Hypothesis: I2C retries as the 3xAA battery drained.
- Timestamp wraps every 71 minutes and must be stitched in post-processing.
- The log is not self-describing: sensor ranges and rates live in source, not in the data.
- No flight state marker, phases are inferred by eye from the accel trace.
- BMP390 oversampling, output rate and filter were left at reset defaults.
- Magnetometer multi-byte reads depended on a HAL quirk (sub-address bit 7 auto-increment) that was never set explicitly.
- Logging halts when flash is full with no boot-time warning.

### 1.4 What already exists in the GAP crate chain

All at `https://github.com/GNAT-Academic-Program/`.

| Crate | Layer | Contents |
|---|---|---|
| `machine_types` | foundation | `MT.UInt8`, `UInt16`, `UInt32` and friends |
| `gpio_generic`, `spi_generic`, `i2c_generic`, `usart_generic`, `debug_generic` | bus generics | Each has `Xxx_Types`, `Xxx_Control`, `Xxx_Data`, `Xxx_Interface`. The `_Interface` generic takes the MCU driver's procedures as formals. |
| `nor_flash_generic` | device class generic | `Nor_Flash_Types` (geometry, JEDEC ID, erase granularity), `Nor_Flash_Control` (init, reset, sleep, wake, erase), `Nor_Flash_Data` (write page, read), `Nor_Flash_Interface` (aggregation). Takes `Bus_Command`, `Bus_Command_Address`, `Bus_Read_Status`, `Bus_Command_Read`, `Bus_Write`, `Bus_Read` as formals, plus a `Device` type. |
| `w25q128` | chip crate | `W25Q128_Spi`: implements the `Bus_*` formals for the Winbond part. Has a bug, see section 3. |
| `touch_generic` + `ft5336` | device class generic + chip crate | The reference pattern for an I2C chip crate. `FT5336_Control` and `FT5336_Data` take `Driver_Write`, `Driver_Write_Read` and `I2C_Address` as formals. |
| `stm32g431_ghal` (crate name `stm32g431`) | MCU crate | `STM32G431_SPI`, `STM32G431_I2C`, `STM32G431_USART` generics, each parameterised by a `Periph` access, `Get_Clock`, `RCC_Enable`, `RCC_Reset`. `Clock_Tree`. SVD bindings. Clock configuration variables in `alire.toml`. |
| `nucleo_g431kb` | board crate | `Instances` instantiates the MCU generics into `Usart_Interface`, `Spi_Interface`, `I2C_Interface`. `Board` renames them `Console`, `Spi_1`, `I2C_1` and exposes `Led`, `Spi_1_Cs`, `Initialize`. `Board_GPIO`, `Board_Log`, `Last_Chance_Handler`. Clock values set in `alire.toml`. |
| `light_tasking_stm32g4xx` | runtime | Ada light tasking runtime for the G4, gives `Ada.Real_Time` and `delay until` |

So the MCU layer and the board layer are done. The port work is entirely above them.

## 2. The crate chain pattern (the reference is `nucleo_g431kb`)

Top to bottom. Every new chain follows this.

```
application crate          thin mains, one per executable
        |
board crate                Instances: MCU generic -> Xxx_Interface generic
                           Board: renames (Console, Spi_1, I2C_1), pins (Led, Spi_1_Cs), Initialize
                           alire.toml: clock configuration values, once
        |
MCU crate (xxx_ghal)       STM32G431_SPI / _I2C / _USART generics over Periph + Clock_Tree
                           SVD bindings
        |
xyz_generic crates         Spi_Types / Spi_Control / Spi_Data / Spi_Interface, same for I2C, USART, GPIO
        |
machine_types              integer types

beside the MCU crate, depending only on xyz_generic + machine_types:
device class generics      nor_flash_generic, touch_generic, (new) imu_generic, baro_generic, gnss_generic
chip crates                w25q128, ft5336, (new) lsm6dso32, bmp390, ublox_m10
```

Rules that make it work:

1. "The instantiation is the bus." `Spi_Interface` and `I2C_Interface` have no device type. Instantiating them once per physical bus is the bus object. Device identity (CS pin for SPI, address for I2C) belongs to the chip crate, not the bus.
2. A chip crate depends only on its class generic, the bus generic it uses, and `machine_types`. It never `with`s an MCU SVD package. A code review that finds `with STM32G431xx` in a chip crate rejects it.
3. The board crate is the only place pins, peripherals and clocks are named. The application never mentions a peripheral.
4. Each layer takes the layer below as generic formals, so swapping a layer is re-instantiation, not editing.
5. Each crate has: `alire.toml` with `url` + `branch` pins (never `path` pins), a `README.md` whose build instructions are one `alr build` box and one flash box per board (never two boards' commands in the same box), a `tests/` directory, and one owner.

Dependency direction for the rocket, as a picture:

```
providentia_avionics ..... executables: flight_logger, flash_dump, sensors_check
        |
providentia_payload ...... the payload daughterboard: nucleo_g431kb + wiring + chip instantiations
        |                   + telemetry.ads (the Sample record)
        |
  flight_journal_generic   imu_generic   baro_generic   gnss_generic   (rocketry-reusable layer)
        |                     |              |              |
  nor_flash_generic       lsm6dso32       bmp390        ublox_m10        (chip crates)
        |                     |              |              |
     w25q128              spi_generic    i2c_generic    usart_generic
        |
  nucleo_g431kb -> stm32g431 -> gpio/spi/i2c/usart_generic -> machine_types
```

## 3. Fixes needed in the existing chain before building on it

1. **`w25q128` does not plug into `spi_generic`.** `W25Q128_Spi` declares `type Spi_Device is limited private` and takes `Spi_Write_Bytes (Dev : in out Spi_Device; Buf : Storage_Array)`. But `Spi_Interface.Write` takes only `Buf`; there is no device parameter because the instantiation is the bus. The comment in the spec saying the signatures match is false. Fix: remove `Spi_Device` from the formals, take `with procedure Spi_Write (Buf : Storage_Array)` and `with procedure Spi_Read (Buf : out Storage_Array)`, keep `Pin_Set` and `Pin_Clear`, and make `Device` a record holding only the CS pin. Keep `nor_flash_generic`'s `Device` type as is; it is what allows two flash chips on one bus with two CS pins.
2. **`stm32g431_ghal/alire.toml` has `path = '../i2c_generic'` pins** for `i2c_generic`, `usart_generic`, `spi_generic`. A student cloning that one repo cannot build. Replace with `url` + `branch` pins like the other entries.
3. **`nucleo_g431kb/src/board.ads` comment says I2C1 on PB6/PB7**, while `instances.ads` instantiates `I2C2_Periph` on PA8/PA9 and names it `I2C_1`. Students wire from comments. Make the comment and the name describe the same silicon.
4. **The `terrarium` crate** in the rocket repo depends on `stm32g4_ghal`, which no longer exists under that name. Delete it or repoint it; it will confuse the next student.

## 4. Hardware for round 2, ranked by payoff per effort

### 4.1 Summary table

| Rank | Item | Kind | Why it matters | Effort |
|---|---|---|---|---|
| 1 | Flight state machine with rate switching | software | Turns one 25-hour 6 Hz log into per-phase logging at the right rate. Fixes the flash-full problem and the resolution problem at once. | one package, host-testable |
| 2 | GPS (u-blox M10) | hardware, cheap | Recovery, absolute time, altitude cross-check. | one chip crate + one generic |
| 3 | LSM6DSO32 IMU on SPI | hardware, cheap | ±32 g range, FIFO, kHz rates. Replaces the LSM9DS1 which was 90 percent of full scale on the April flight. | one chip crate + one generic |
| 4 | Keep BMP390, add a proper static port | hardware, free | The sensor is fine; a missing vent hole makes altitude lag and apogee wrong. | airframe checklist item |
| 5 | LiPo power + battery voltage logged | hardware, cheap | Explains and prevents the loop slowdown seen in April. | one ADC driver in the GHAL layer |
| 6 | Keep W25Q128, add arm/disarm | software | Bench testing must not consume flight storage. | journal feature |
| 7 | LoRa downlink | hardware, medium | Live state and position for the ground crew. | after 1 to 6 fly once |
| 8 | Stay on Nucleo G431KB | decision | Enough MCU; the chain is built. | none |
| 9 | Connectors, strain relief, conformal coat | mechanical | Vibration is where rockets actually fail. | integration checklist |
| 10 | Ground test plan | process | Baro, IMU and state machine tested without a launch. | ongoing |

### 4.2 IMU: LSM6DSO32

Why it is the right part:

- Accelerometer ±4, ±8, ±16, ±32 g. The April flight logged 14.5 g on a ±16 g setting, which is 90 percent of full scale. At ±32 g that same event is 45 percent, with room for a bigger motor or an ejection transient. Resolution at ±32 g is about 0.976 mg per LSB, still far finer than needed.
- Gyroscope ±125 to ±2000 dps. Same ceiling as before. Fine unless the vehicle is spin stabilised.
- ODR up to 6.66 kHz with configurable low-pass filters. The motor vibrates the airframe at hundreds of Hz; sampling slower than that without a filter folds (aliases) the vibration into the acceleration data. The filter plus a high rate fixes that.
- 9 KB FIFO with timestamps. The sensor stores hundreds of samples; the MCU drains them in one burst. Loop jitter stops mattering because the sensor timestamps the samples, not the loop.
- Same register family as LSM6DSO and LSM6DSOX, so one driver covers three parts and reference code is abundant.
- I2C address 0x6A or 0x6B (SA0 pin), or SPI up to 10 MHz.

What is lost: no magnetometer. For a 10K COTS flight heading is not a flight state anyone needs, and the LSM9DS1 magnetometer was the axis never configured properly anyway. The `telemetry.ads` sample loses three fields.

Bus recommendation: SPI, on the same bus as the flash with its own CS pin. The IMU is the high-bandwidth device; a FIFO drain over I2C at 400 kHz is capped around 3 KB per 100 ms and competes with baro reads. Needs one more CS pin exposed by the board crate.

Optional addition: ADXL375, a ±200 g accelerometer, I2C, about twenty dollars. Only if the experiment needs to measure shock events (ejection charge, landing) rather than call them unresolved transients. Low priority for a flight data logger, relevant for a payload experiment about shock loading.

### 4.3 Barometer: BMP390

The sensor is good: about 0.25 m altitude resolution at useful oversampling. Keep it. Three things to do properly this time:

- Write PWR_CTRL, OSR, ODR and CONFIG explicitly at init. The April firmware left three of them at reset defaults, a combination the datasheet warns against (measurement time longer than the output period).
- Read the factory calibration coefficients (21 bytes at register 0x31) and store them in the log header so the host can compensate.
- Static port. One 1/4 inch hole per 100 cubic inches of bay volume is the usual altimeter maker rule, three or four holes spaced around the circumference, away from the nose cone shoulder and any surface that sees ram pressure. This is an airframe integration item, not code, and it decides whether the altitude trace means anything.

Alternative considered: MS5611. Older, no advantage. Not recommended.

### 4.4 GPS: u-blox M10 (SAM-M10Q or MAX-M10S breakout)

- UART, 10 Hz position rate, UBX binary protocol. UBX is smaller and easier to parse in Ada than NMEA text.
- Must be configured for the airborne dynamic model (under 4 g). The default "portable" model assumes a pedestrian and loses lock under boost.
- Civilian GPS modules stop reporting above 18 km altitude or 1000 knots. The M10 applies this as an AND (both conditions), so a 10K feet flight at a few hundred knots is fine. Some cheap clones apply it as an OR and drop out. Buy the genuine module.
- Gives latitude, longitude, altitude, UTC time and fix quality. Altitude cross-checks the baro. UTC anchors the whole log to absolute time, which the April log lacked. Position is what you need to find the rocket.

### 4.5 Storage: W25Q128

16 MB, 65 536 pages of 256 bytes, 4096 sectors of 4 KB. With rate switching (section 6.2) this is a dozen flights of capacity. Keep it.

SD card with a FAT filesystem was considered and rejected: more code, more failure modes under vibration (card seating), nothing gained.

Add: arm/disarm. A jumper, a switch, or a console command. The journal refuses to write unless armed, and refuses to open for writing if the header says the last flight has not been dumped. Bench testing then never eats flight storage.

### 4.6 Power

The April loop slowed from 6.6 Hz to 5 Hz over 25 hours on 3xAA. The author's own hypothesis is I2C retries as the supply sagged. Fix:

- 1S LiPo (or 2S with a buck converter), then a 3.3 V LDO with enough dropout headroom.
- Sample battery voltage through the STM32G431 ADC and log it in every page trailer. This needs an `adc` driver in `stm32g431_ghal` and an `adc_generic`, which the chain does not have yet and will want for everything else anyway.
- Battery physically retained in the bay, not held by its own wires.

### 4.7 Downlink: LoRa (optional, later)

RFM95 or SX1276 breakout, 915 MHz in the US, SPI. Sends state, GPS position, altitude once per second. Receiver on the ground with a small app. Lets the crew see "Landed" and a position instead of guessing. Do it after the logger flies once.

### 4.8 Microcontroller: stay on the Nucleo-G431KB

STM32G431KBT6: Cortex-M4F at up to 170 MHz, 128 KB flash, 32 KB RAM, hardware FPU. 32 KB RAM is enough for a 256-byte page buffer, a FIFO drain buffer of a few KB, and a UBX parser. Nothing bigger buys anything usable, and the chain is already built for it. Freya (the GAP reference board) is the long game, not something to gate a flight on.

### 4.9 Mechanical and wiring

No breadboard jumpers in an airframe. Soldered perfboard or a small PCB. JST-PH or JST-GH connectors with latches. Strain relief on every cable. Conformal coating on the boards. The April payload survived 45 seconds on a modest motor; a 10K flight on a bigger motor is a different vibration environment.

### 4.10 What not to do

- A second microcontroller.
- An RTOS or tasking on the flight path. Keep the sequential loop with `delay until`; it is readable and the timing can be checked by reading the source.
- An SD card.
- A Kalman filter or sensor fusion before the raw data is clean and the state machine works on raw thresholds.

None of these change what is recovered from the flash.

### 4.11 Ground test plan (no rocket needed)

| Test | Checks |
|---|---|
| Replay the April log through the state machine on the host | Boost and apogee detected where the plot shows them |
| Syringe or vacuum chamber on the BMP390 | Altitude pipeline and apogee detection |
| Drop test and a drill-driven eccentric weight on the IMU | Range, filter settings, aliasing |
| Renode with the existing BMP390 model | Chip crate without hardware |
| Full system on the bench, armed, 24 hours | Rate switching, battery field, no flash consumed on the pad |
| Readback of every flight on the bench before erasing | `flash_dump` works, header is self-describing |

## 5. Software architecture

### 5.1 Crate inventory for the port

| Crate | New or existing | Layer | Depends on |
|---|---|---|---|
| `imu_generic` | new | device class generic | `machine_types` |
| `baro_generic` | new | device class generic | `machine_types` |
| `gnss_generic` | new, later | device class generic | `machine_types` |
| `lsm6dso32` | new | chip crate | `imu_generic`, `spi_generic` (or `i2c_generic`), `machine_types` |
| `bmp390` | new | chip crate | `baro_generic`, `i2c_generic`, `machine_types` |
| `ublox_m10` | new, later | chip crate | `gnss_generic`, `usart_generic`, `machine_types` |
| `w25q128` | existing, fix formals | chip crate | `nor_flash_generic`, `spi_generic`, `gpio_generic`, `machine_types` |
| `flight_journal_generic` | new | rocketry generic | `nor_flash_generic` types, `machine_types` |
| `flight_state_generic` | new | rocketry generic | `machine_types` only, pure logic |
| `adc_generic` + ADC driver in `stm32g431` | new, for battery voltage | bus generic + MCU | as the other bus generics |
| `providentia_payload` | new | board-level instantiation for the payload | `nucleo_g431kb`, all chip crates, both rocketry generics |
| `providentia_avionics` | new, replaces `terrarium_pico` | application | `providentia_payload` |

### 5.2 Device class generics: why they exist

The question "do we need `imu_generic` or is the chip crate enough" was raised and answered yes, for two reasons:

1. The existing chain already does it: `ft5336` sits under `touch_generic`, `w25q128` under `nor_flash_generic`. A chip crate with no class above it would be the inconsistency.
2. Rocketry teams swap sensors every year. If the journal, the sample record and the mains depend on `Imu_Interface`, swapping the LSM6DSO32 for a BMI088 next year is a new chip crate plus one line in `Payload`. If they depend on `LSM6DSO32_Interface`, it is a rewrite of the application by students who did not write it.

The line between generic and chip crate: the generic holds what every chip in the class has. Anything only one chip has stays in the chip crate until a second chip needs it.

#### `imu_generic`

- `Imu_Types`: `Raw_Vector` (three `Integer_16`), `Axis`, `Accel_Range (G2, G4, G8, G16, G24, G32)`, `Gyro_Range (DPS_125, DPS_250, DPS_500, DPS_1000, DPS_2000, DPS_4000)`, `Imu_Config (Accel_Range, Gyro_Range, Accel_ODR_Hz, Gyro_ODR_Hz)`, `Imu_Caps (Has_Mag : Boolean; Has_Fifo : Boolean; Max_Accel_Range; Max_Gyro_Range)`, `Raw_Sample (Accel, Gyro : Raw_Vector; Timestamp : UInt32)`, `Raw_Sample_Array`, `Imu_Error` and `Imu_Unsupported` exceptions. Scale functions `Accel_LSB_Per_G (Range)` and `Gyro_LSB_Per_DPS (Range)` defined once, here.
- `Imu_Control`: `Init (Cfg)`, `Check_Id return Boolean`, `Capabilities return Imu_Caps`.
- `Imu_Data`: `Read_Accel`, `Read_Gyro`, `Read_Mag` (raises `Imu_Unsupported` when `Has_Mag` is False), `Accel_Ready`, `Gyro_Ready`, `Read_Batch (Buf : out Raw_Sample_Array; Count : out Natural)`. Polling chips implement `Read_Batch` as "read one sample, return 1". FIFO chips drain. The logger always consumes batches.
- `Imu_Interface`: aggregation with formals `Driver_Init`, `Driver_Check_Id`, `Driver_Capabilities`, `Driver_Read_Accel`, `Driver_Read_Gyro`, `Driver_Read_Mag`, `Driver_Read_Batch`.
- Out of scope until a second chip needs them: interrupts, magnetometer calibration, tap and wake detection, filter configuration beyond "bypass or on".

#### `baro_generic`

- `Baro_Types`: `Raw_Sample (Pressure, Temperature : UInt32)` (24-bit payload stored in 32), `Oversampling (X1, X2, X4, X8, X16, X32)`, `Baro_Config (Pressure_OSR, Temperature_OSR, ODR_Hz, Filter_On : Boolean)`, `Pressure_Pa`, `Temperature_C` as `Float` (the G4 has an FPU), `Baro_Error`.
- `Baro_Control`: `Init (Cfg)`, `Check_Id`, `Read_Calibration` (chip-sized opaque blob, kept by the chip crate, exposed as a `Storage_Array` so the journal can store it in the header).
- `Baro_Data`: `Data_Ready`, `Read_Raw`, `Compensate (Raw) return (Pressure_Pa, Temperature_C)` as a formal, because every chip's polynomial differs but the signature does not.
- Altitude from pressure is not in the generic; it is a pure function in `flight_state_generic` (or a tiny `altitude` package) using the standard atmosphere, since it does not depend on the chip.

#### `gnss_generic` (later)

- `Gnss_Types`: `Fix (Lat, Lon : Integer_32 in 1e-7 degrees; Alt_mm : Integer_32; UTC; Fix_Quality; Satellites)`.
- `Gnss_Control`: `Init`, `Set_Dynamic_Model (Airborne_4g)`.
- `Gnss_Data`: `Poll (Fix, Valid)`.

### 5.3 Chip crates

#### `lsm6dso32`

- Pattern copied from `ft5336`: `lsm6dso32_types` (register map, who-am-I value 0x6C), `lsm6dso32_control`, `lsm6dso32_data`, `lsm6dso32_interface`.
- Formals on SPI: `Spi_Write`, `Spi_Read`, `Pin_Set`, `Pin_Clear` plus a `Device` record with the CS pin, same shape as the fixed `w25q128`. If I2C is chosen instead: `Driver_Write`, `Driver_Write_Read`, `I2C_Address`.
- Maps `Accel_Range` to the CTRL1_XL bits, raises `Imu_Unsupported` for `G24`. Maps `Gyro_Range` to CTRL2_G. `Read_Batch` drains the FIFO.
- Exports exactly the procedures `Imu_Interface` wants as formals.

#### `bmp390`

- `bmp390_types` (register map, chip id 0x60, calibration record layout), `bmp390_control` (writes PWR_CTRL 0x1B, OSR 0x1C, ODR 0x1D, CONFIG 0x1F explicitly; reads calibration at 0x31), `bmp390_data` (data-ready bit in STATUS 0x03, raw read of 6 bytes from 0x04, compensation per datasheet section 8.4).
- Formals: `Driver_Write`, `Driver_Write_Read`, `I2C_Address`.
- The existing Renode BMP390 model from the F746 work gives this crate a simulated test from day one.

#### I2C address conversion (the first thing that bites in the port)

`I2C_Types.I2C_Address` is `mod 2**7`, the 7-bit form. The Pico code and its README use the 8-bit shifted form. Divide by two.

| Device | Pico 8-bit form | GHAL 7-bit form |
|---|---|---|
| LSM9DS1 accel/gyro | 0xD6 | 0x6B |
| LSM9DS1 magnetometer | 0x3C | 0x1E |
| BMP390 (SDO high) | 0xEE | 0x77 |
| LSM6DSO32 (SA0 low / high) | 0xD4 / 0xD6 | 0x6A / 0x6B |

Put this table in every chip crate README.

### 5.4 `flight_journal_generic`: the recyclable rocketry asset

This is `flight_logger`'s page logic and `flash_reader`'s page logic merged into one package, so writer and reader can never disagree on layout again.

Generic formals:

- `type Record_Type is private` and `Record_Size : Natural`, checked at elaboration against `Record_Type'Size / 8`.
- `Page_Size`, `Sector_Size`, `Total_Pages`, taken from the `Nor_Flash_Types.Nor_Config` of the chip.
- `with procedure Flash_Write_Page (Addr; Buf)`, `Flash_Read (Addr; Buf)`, `Flash_Erase_Sector (Idx)`, matching `Nor_Flash_Interface`.
- `with function Now return UInt32`, the microsecond timestamp source.
- `with function Armed return Boolean`.

Operations:

- `Open (Mode : Read_Only | Append)`: reads the header page, scans for the first erased page (resume after power cycle), reports `Pages_Used`, `Full`, and `Needs_Dump` (last flight not yet read back). Refuses `Append` when not armed or when `Needs_Dump`.
- `Append (R : Record_Type)`: buffers in RAM, flushes a page when full, erases the next sector when the write pointer crosses a sector boundary (erase on demand, as before).
- `Flush`: write the partial page now (used at state transitions and on `Landed`).
- `Erase_All`: full chip erase, only from a console command, after a dump.
- `Read_Page (Idx; out Records; out Trailer)` and `Iterate` for the dump executable.
- `Mark_Dumped`: writes a flag the next `Open (Append)` checks.

Page layout:

- Page 0: header. Format version, `Record_Size`, records per page, timestamp unit, IMU config enums, baro config enums, baro calibration blob, board id string. This makes the log self-describing.
- Data pages: N records, then a trailer: 4-byte page sequence number, 4-byte timestamp epoch counter (increments each time `Now` wraps, so 71-minute wraps are handled on board), 2-byte battery voltage in mV, 1-byte flight state, padding. Everything the April README asked for, at a cost of about 12 bytes per page.
- An erased sequence number (0xFFFFFFFF) still means "never written".

Record serialization: no hand-written `Pack_U32`. The sample is an Ada record with a representation clause (`for Sample use record ... end record`, `Scalar_Storage_Order => System.Low_Order_First`, `Sample'Size use 8 * Record_Size`) converted to `Storage_Array` with `Ada.Unchecked_Conversion`. The compiler enforces the layout; `fileprocess.py` reads the same bytes.

### 5.5 `flight_state_generic`: the biggest single win

Pure logic, no hardware, testable on the host with the April log as input.

States: `Idle` (not armed), `Pad` (armed, waiting), `Boost`, `Coast`, `Descent`, `Landed`.

Inputs per step: accel magnitude (g), baro altitude above pad (m), time.

Transitions (initial thresholds, to be tuned on the April data):

- `Pad` to `Boost`: accel magnitude above 3 g for more than 100 ms.
- `Boost` to `Coast`: accel magnitude drops below 1.5 g for more than 200 ms.
- `Coast` to `Descent`: altitude decreasing for more than 1 s (apogee detected by baro, with a lockout of a few seconds after burnout so the pressure spike at high speed does not trigger it early).
- `Descent` to `Landed`: altitude change under 2 m and accel magnitude near 1 g for more than 10 s.

Logging rate per state, set by the main loop from the state:

| State | IMU rate | Baro rate | Why |
|---|---|---|---|
| Idle | none | none | Flash is not consumed on the bench |
| Pad | 1 Hz | 1 Hz | Health only; could be a short ring buffer so the seconds before liftoff are kept |
| Boost, Coast | 500 Hz to 1 kHz from the FIFO | 50 Hz | Resolve the motor and the transients |
| Descent | 50 Hz | 10 Hz | Nothing fast happens |
| Landed | one final flush, then stop | | |

The state byte goes in every page trailer and the state transitions are logged as events, so post-processing never has to infer phases from the accel trace again.

### 5.6 `providentia_payload`: the board-level instantiation for the payload

The Nucleo is the MCU board; the payload daughterboard with the sensors and the flash is the thing being instantiated here. One `Payload` package:

```ada
package Flash   is new W25Q128_Spi        (Spi_Write => Board.Spi_1.Write,
                                           Spi_Read  => Board.Spi_1.Read,
                                           Pin_Set   => Gpio.Set,
                                           Pin_Clear => Gpio.Clear);
package Imu     is new Imu_Interface      (Driver_Init => LSM6DSO32.Init, ...);
package Baro    is new Baro_Interface     (Driver_Init => BMP390.Init, ...,
                                           I2C_Address => 16#77#);
package Journal is new Flight_Journal     (Record_Type => Telemetry.Sample, ...,
                                           Now => Clock_Us,
                                           Armed => Arm_Pin_Is_Set);
package Flight  is new Flight_State       (...);

procedure Initialize;
--  Board.Initialize, open Spi_1 at F_10M mode 0, open I2C_1 at Fast_Mode,
--  open flash, check JEDEC, init sensors, check ids, log everything to Console.
```

Plus `telemetry.ads`: the `Sample` record (timestamp, accel vector, gyro vector, baro raw, state byte, and later the GNSS fix), with its representation clause.

Timestamp source: `Ada.Real_Time.Clock` from the light tasking runtime, converted to microseconds since boot. No timer register peek.

Students building a new experiment on the same hardware depend on this crate and write a 60-line main. Students building new hardware copy this crate and change pins, addresses and chip crates.

### 5.7 `providentia_avionics`: the application

Replaces `terrarium_pico`. Three mains, each 50 to 100 lines:

| Executable | Replaces | What it does |
|---|---|---|
| `flight_logger` | `flight_logger.adb` | `Payload.Initialize`, then a fixed-period loop (`delay until`) that drains the IMU batch, reads the baro when due, steps the state machine, appends records, flushes on state change. |
| `flash_dump` | `flash_reader.adb`, `flash_reader_2.adb` | `Journal.Open (Read_Only)`, prints the header, then one record per line to `Board.Console`, then `Mark_Dumped` on request. |
| `sensors_check` | `i2c_sensors.adb`, `i2c_demo.adb`, `spi_flash_test.adb` | Check every chip id, JEDEC, print a few samples, print battery voltage. The first thing run on a new board. |

`flight_data/fileprocess.py` stays, updated to read the header page and the trailer fields.

## 6. The port, step by step

Each step ends with something that runs on the Nucleo and a commit. Expect it to be messy; the point is that each step is small enough to keep.

| Step | Work | Proves |
|---|---|---|
| 0 | Fix the four chain issues in section 3. Delete the stale `terrarium` crate. | A clean clone of any crate builds |
| 1 | Port `spi_flash_test` against the fixed `w25q128` + `Board.Spi_1` + `Board.Spi_1_Cs`. JEDEC, erase, write, read. | The whole chain works end to end on the flash |
| 2 | `baro_generic` + `bmp390` + `sensors_check` reading only the baro. Develop on Renode first if the board is not at hand. | I2C path, chip crate pattern |
| 3 | `imu_generic` + `lsm6dso32` on SPI (needs a second CS pin in `nucleo_g431kb`). Extend `sensors_check`. | FIFO drain, batch API |
| 4 | `flight_journal_generic` + `telemetry.ads` + `flight_logger` + `flash_dump`. Header page, trailer, resume, arm. | The logger flies on the bench |
| 5 | `flight_state_generic`, tested on the host against the April log, then wired into `flight_logger` with rate switching. | Per-phase logging |
| 6 | `adc_generic` + ADC in `stm32g431` + battery voltage in the trailer. | Power health |
| 7 | `fileprocess.py` for the new format. 24-hour armed bench run. Compare against April numbers. | Ready for a ground campaign |
| 8 | `gnss_generic` + `ublox_m10`, GNSS fix in the sample. | Recovery |
| 9 | LoRa downlink, ground receiver. | Optional |

## 7. Team rules

- One repo per crate, one owner per crate, reviewed by someone else.
- `alire.toml` pins by `url` and `branch` until a crate is published to the Alire index. Never `path`.
- README per crate: what it is, which layer, the dependency rule, one `alr build` box, one flash box per board, the I2C address table where relevant, the "things that bit us" list.
- `tests/` per crate with at least the id check or a host-side unit test for pure packages.
- Dependency direction is the review rule: application depends on payload, payload depends on chips and board, chips depend only on `xyz_generic` + `machine_types`.
- The chip crates and the two rocketry generics are what outlives this rocket. The Nucleo and the payload crate are what gets copied for the next one.

## 8. Open decisions

| Decision | Options | Current lean |
|---|---|---|
| LSM6DSO32 bus | SPI (second CS on the Nucleo) or I2C (shared with the baro) | SPI, for FIFO drains |
| ADXL375 high-g accelerometer | Add or skip | Skip unless the payload experiment is about shock |
| Arm mechanism | Jumper, switch, console command, or GPS-motion based | Jumper plus console command |
| Pad pre-trigger buffer | Keep last N seconds before `Boost` in RAM and flush them on liftoff, or not | Yes, small ring buffer, cheap |
| Altitude computation on board | Needed for the state machine; standard atmosphere from baro, or raw pressure thresholds | Standard atmosphere, `Float`, the G4 has an FPU |
| GNSS in the sample record or in a separate record type | One record type keeps the journal simple; two types need a tag byte | One record, fix fields zero when invalid |
| Record size | 22 bytes without mag, more with GNSS and state | Decide when `telemetry.ads` is written, keep records per page a whole number |
| Flight-state thresholds | Initial values in section 5.5 | Tune on the April log before anything else |