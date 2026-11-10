--  bmp3xx.ads
--  Bosch BMP388 / BMP390 barometer driver, independent of the bus. Part of
--  the bmp3xx chip crate. Instantiate once per physical chip; the
--  instantiation is the device, like Spi_Interface is the bus.
--
--  General plan:
--  Init does everything needed to trust the readings afterward:
--     1. CHIP_ID check, so the wrong part or no part fails early
--     2. Soft reset, poll cmd_rdy, check PWR_CTRL and OSR are back at
--        power-on values. The chip keeps power across an MCU reset, and
--        on the Pico a mode change sent mid-measurement was ignored, which
--        froze one whole bench run.
--     3. Read the 21-byte trim block
--     4. Reject settings whose conversion time doesn't fit in one output
--        period (DS 3.9.2), which terrarium_pico flew with
--     5. Write OSR, ODR, CONFIG, then PWR_CTRL last so measuring starts
--        with the new settings
--     6. Check ERR_REG.conf_err, and read PWR_CTRL back
--     7. Wait for a fresh result, so a chip that didn't start fails here
--        rather than logging one frozen value all flight
--  Read returns compensated values in Baro_Types units (1/64 Pa,
--  1/100 degree C), worked out in 64-bit integers.
--
--  The chip is reached only through two register formals, so the same
--  driver runs over I2C or SPI. BMP3XX_I2C_Bus and BMP3XX_SPI_Bus turn a
--  bus into those two procedures:
--
--     package Baro_Bus is new BMP3XX_I2C_Bus
--       (Driver_Write_Read => Board.I2C_1.Write_Read,
--        Driver_Write      => Board.I2C_1.Write,
--        I2C_Address       => BMP3XX_Types.I2C_Addr_SDO_High);
--
--     package Baro_Chip is new BMP3XX
--       (Read_Registers   => Baro_Bus.Read_Registers,
--        Write_Register   => Baro_Bus.Write_Register,
--        Expected_Chip_ID => BMP3XX_Types.BMP390_Chip_ID,
--        Delay_Ms         => Delay_Ms);
--
--  For another bus (a second I2C, a bit-banged bus, a test fake), write
--  the two procedures and pass them in; nothing here changes.
--
--  The procedures below have the profiles Baro_Interface takes as formals,
--  so Payload passes them straight through.
--
--  Bus errors: the GHAL bus generics report a NACK or timeout by raising,
--  which this driver can't catch (No_Exception_Propagation). Ok here
--  covers what the chip reports.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

with Baro_Types;
with BMP3XX_Types; use BMP3XX_Types;

generic
   --  Read Data'Length registers starting at Reg. The chip auto-increments
   --  on both buses.
   with procedure Read_Registers (Reg : Unsigned_8; Data : out Storage_Array);

   --  Write Value to register Reg.
   with procedure Write_Register (Reg : Unsigned_8; Value : Unsigned_8);

   --  BMP390_Chip_ID or BMP388_Chip_ID. Init rejects the other part, so
   --  the log always knows which chip it came from.
   Expected_Chip_ID : Unsigned_8;

   --  wait at least Ms milliseconds
   with procedure Delay_Ms (Ms : Natural);
package BMP3XX is

   ---------------------------------------------------------------------
   --  Baro_Interface formals
   ---------------------------------------------------------------------

   --  Reset, check and configure the chip for normal mode with Cfg, then
   --  wait for the first fresh result. Blocks for about 5 ms plus up to two
   --  output periods. Ok is False at the first step that fails; see the
   --  plan above.
   procedure Init (Cfg : Baro_Types.Baro_Config; Ok : out Boolean);

   --  Returns True if CHIP_ID reads Expected_Chip_ID. Doesn't need Init.
   function Check_Id return Boolean;

   --  Returns True if a new pressure and temperature are both waiting.
   --  False before Init succeeds.
   function Data_Ready return Boolean;

   --  Read the latest pressure and temperature, compensated. Both are 0 and
   --  Ok is False before Init succeeds.
   procedure Read (R : out Baro_Types.Reading; Ok : out Boolean);

   --  Read the latest pressure and temperature as the 24-bit ADC values.
   --  Both are 0 and Ok is False before Init succeeds.
   procedure Read_Raw (R : out Baro_Types.Raw_Reading; Ok : out Boolean);

   --  Returns Raw compensated with the trim Init read. All zero before
   --  Init has read the trim.
   function Compensate
     (Raw : Baro_Types.Raw_Reading) return Baro_Types.Reading;

   --  The 21 trim bytes read by Init. Length is 0 and Ok is False before
   --  Init has read them.
   procedure Read_Calibration
     (Cal : out Baro_Types.Calibration_Blob;
      Ok  : out Boolean);

   ---------------------------------------------------------------------
   --  Extras, for tests and the bench
   ---------------------------------------------------------------------

   --  Read at full resolution, 0.01 Pa and 0.01 degree C.
   procedure Read_Fixed (F : out Fixed_Reading; Ok : out Boolean);

   --  Returns Raw compensated at full resolution. Zero before Init has
   --  read the trim.
   function Compensate_Fixed (Raw : Baro_Types.Raw_Reading)
     return Fixed_Reading;

   --  Returns the ODR register code for Cfg.Rate_Hz: the fastest rate at or
   --  below it, from 200 Hz halving down to about 0.0015 Hz.
   function ODR_Code (Rate_Hz : Positive) return Natural;

   --  Returns the worst-case time in microseconds for one pressure and
   --  temperature conversion at Cfg's oversampling (DS 3.9.2).
   function Conversion_Time_Us (Cfg : Baro_Types.Baro_Config) return Natural;

   --  Returns True if a conversion at Cfg's oversampling finishes inside one
   --  output period at Cfg's rate. Init refuses settings where it doesn't.
   function Settings_Fit (Cfg : Baro_Types.Baro_Config) return Boolean;

   --  Returns F in Baro_Types units, rounded, held inside their ranges.
   function To_Reading (F : Fixed_Reading) return Baro_Types.Reading;

end BMP3XX;
