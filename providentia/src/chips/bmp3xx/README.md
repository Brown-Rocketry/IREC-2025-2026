# bmp3xx

Chip crate for the Bosch BMP388 and BMP390 barometers over I2C or SPI, for the GHAL chain. It lives inside `providentia` for now and moves to its own repository once the interfaces settle.

**Layer:** chip crate. It depends only on `baro_generic`, `i2c_generic` and `machine_types`. It never names an MCU, pin or board.

**Status:** passes the host tests (421 reference vectors plus a fake chip, run over both buses) and the SPARK overflow proof for the compensation. **Not yet run on hardware**, on either bus.

## Files

| File | Contents |
| --- | --- |
| `bmp3xx_types.ads` | Register map, chip IDs, I2C addresses, trim register layout |
| `bmp3xx_compensation.ads/.adb` | 64-bit integer compensation, SPARK-proved free of overflow |
| `bmp3xx.ads/.adb` | The driver. Generic over two register procedures, the expected chip ID and a delay, so it never sees the bus |
| `bmp3xx_i2c_bus.ads/.adb` | Register access over I2C: address, then a repeated-start read |
| `bmp3xx_spi_bus.ads/.adb` | Register access over 4-wire SPI: read bit 7, one dummy byte, chip select per access |

## Use

The driver reaches the chip only through `Read_Registers` and `Write_Register`. A bus adapter turns a bus into those two procedures, so choosing a bus is choosing an adapter. The driver's procedures match `Baro_Interface`'s formals and go straight through.

Over I2C (the adapter's formals match `I2C_Interface`):

```ada
package Baro_Bus is new BMP3XX_I2C_Bus
  (Driver_Write_Read => Board.I2C_1.Write_Read,
   Driver_Write      => Board.I2C_1.Write,
   I2C_Address       => BMP3XX_Types.I2C_Addr_SDO_High);
```

Over SPI (the adapter's formals match `Spi_Interface`; chip select comes in as two procedures, so this crate never names a GPIO type). Open the bus in mode 0 or 3, at most 10 MHz:

```ada
package Baro_Bus is new BMP3XX_SPI_Bus
  (Spi_Write   => Board.Spi_1.Write,
   Spi_Read    => Board.Spi_1.Read,
   Select_Chip => Baro_Cs_Low,
   Release     => Baro_Cs_High);
```

Then, the same for either bus:

```ada
package Baro_Chip is new BMP3XX
  (Read_Registers   => Baro_Bus.Read_Registers,
   Write_Register   => Baro_Bus.Write_Register,
   Expected_Chip_ID => BMP3XX_Types.BMP390_Chip_ID,
   Delay_Ms         => Delay_Ms);

package Baro is new Baro_Interface
  (Driver_Init             => Baro_Chip.Init,
   Driver_Check_Id         => Baro_Chip.Check_Id,
   Driver_Data_Ready       => Baro_Chip.Data_Ready,
   Driver_Read             => Baro_Chip.Read,
   Driver_Read_Calibration => Baro_Chip.Read_Calibration);
```

For any other bus (a second I2C, a bit-banged bus, a test fake), write the two register procedures and pass them to `BMP3XX`.

## I2C addresses

GHAL's `I2C_Address` is the 7-bit form. The Pico code used the 8-bit form, so halve it.

| SDO pin | Pico 8-bit form | GHAL 7-bit form |
| --- | --- | --- |
| GND | 0xEC | 0x76 |
| VDDIO (Adafruit default) | 0xEE | 0x77 |

## Test

```bash
cd tests/bmp3xx && ./run.sh
```

## Things that bit us

- **Readings froze for a whole bench run.** The chip keeps power across an MCU reset and ignored a mode change sent mid-measurement (ada-flight-logger, November 2026). `Init` now soft resets the chip, reads `PWR_CTRL` back, and waits for a fresh result.
- **The oversampling took longer than the output period.** terrarium_pico flew X8 at the 200 Hz default, which the datasheet warns against. `Init` refuses settings whose conversion time (DS 3.9.2) doesn't fit in one period, before it writes anything.
- **OSR reads 0x00 after reset, not 0x02.** Both datasheets say 0x02, but real BMP390 and BMP388 chips read 0x00 (Ada-Device-Drivers bench). Both values are accepted.
- **Bosch's integer pressure formula overflows 64 bits** for some legal trims. The compensation here uses one 2^36 scale instead, and SPARK proves it can't overflow.
- **SPI needs a CS edge before it works.** The chip powers up on I2C and only switches to SPI at the first falling edge of CSB, until it loses power (DS 5.1). `BMP3XX_SPI_Bus` pulses CS once on its own before its first access, so the `CHIP_ID` read in `Init` is already on SPI.
- **SPI reads have a dummy byte.** The BMP280 didn't; the BMP3xx sends one junk byte after the address on every read (DS 5.3.2). The adapter skips it, and the host test fails if it doesn't.
- **Bus errors raise.** `I2C_Interface` raises `Bus_Fault` on a NACK, and the runtime can't catch it (`No_Exception_Propagation`), so a bus error still reaches the last chance handler. `Ok` covers what the chip reports.

## Not done

- SPI on hardware. The adapter follows DS 5.1 and 5.3 and passes against the fake, but no real chip has answered it yet. Wiring for SPI: CSB to a GPIO (not to VDDIO, which locks the chip to I2C), SDO to MISO, SDI to MOSI, SCK to SCK.
- 3-wire SPI (`IF_CONF.spi3`).
- FIFO and interrupts.
