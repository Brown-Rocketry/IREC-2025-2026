--  bmp3xx_types.ads
--  Bosch BMP3xx barometer family (BMP388, BMP390): register map, identity
--  values and the trim register layout. Part of the bmp3xx chip crate. No
--  hardware access.
--
--  General plan:
--  The BMP388 and BMP390 share their register map, trim block and
--  compensation formula; CHIP_ID is the only difference. So the driver is
--  one generic, BMP3XX, and the part is chosen by the Expected_Chip_ID
--  it is instantiated with.
--
--  Ported from Ada-Device-Drivers (Devices.BMP3XX and .Registers), with
--  the HAL types replaced by Interfaces and Storage_Array for the GHAL
--  chain.
--
--  Reference: BMP390 datasheet BST-BMP390-DS002, BMP388 datasheet
--             BST-BMP388-DS001
--    Memory map: Table 25 (4.2), trim registers: Table 24 (3.11.1)

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

package BMP3XX_Types
  with Pure, SPARK_Mode
is
   --  CHIP_ID readback for each part
   BMP388_Chip_ID : constant Unsigned_8 := 16#50#;
   BMP390_Chip_ID : constant Unsigned_8 := 16#60#;

   --  7-bit I2C address, set by the SDO pin. The Pico code used the 8-bit
   --  form (0xEE); GHAL's I2C_Address is 7-bit, so halve it.
   --     SDO to GND    16#76#   (8-bit form 0xEC)
   --     SDO to VDDIO  16#77#   (8-bit form 0xEE), Adafruit default
   I2C_Addr_SDO_Low  : constant := 16#76#;
   I2C_Addr_SDO_High : constant := 16#77#;

   ---------------------------------------------------------------------
   --  Registers (DS 4.2, Table 25)
   ---------------------------------------------------------------------

   REG_CHIP_ID    : constant Unsigned_8 := 16#00#;
   REG_ERR_REG    : constant Unsigned_8 := 16#02#;
   REG_STATUS     : constant Unsigned_8 := 16#03#;
   REG_DATA_0     : constant Unsigned_8 := 16#04#;  --  press 7:0, then temp
   REG_PWR_CTRL   : constant Unsigned_8 := 16#1B#;
   REG_OSR        : constant Unsigned_8 := 16#1C#;
   REG_ODR        : constant Unsigned_8 := 16#1D#;
   REG_CONFIG     : constant Unsigned_8 := 16#1F#;
   REG_CALIB_DATA : constant Unsigned_8 := 16#31#;  --  21 bytes, Table 24
   REG_CMD        : constant Unsigned_8 := 16#7E#;

   --  ERR_REG (DS 4.3.3)
   ERR_FATAL_Msk : constant Unsigned_8 := 16#01#;
   ERR_CONF_Msk  : constant Unsigned_8 := 16#04#;  --  cleared on read

   --  STATUS (DS 4.3.4)
   STATUS_CMD_RDY_Msk    : constant Unsigned_8 := 16#10#;
   STATUS_DRDY_PRESS_Msk : constant Unsigned_8 := 16#20#;
   STATUS_DRDY_TEMP_Msk  : constant Unsigned_8 := 16#40#;

   --  PWR_CTRL (DS 4.3.17): press_en bit 0, temp_en bit 1, mode bits 5:4
   PWR_CTRL_PRESS_EN : constant Unsigned_8 := 16#01#;
   PWR_CTRL_TEMP_EN  : constant Unsigned_8 := 16#02#;
   PWR_CTRL_NORMAL   : constant Unsigned_8 := 16#30#;
   PWR_CTRL_Used_Msk : constant Unsigned_8 := 16#33#;

   --  CMD (DS 4.3.23)
   CMD_SOFTRESET : constant Unsigned_8 := 16#B6#;

   --  Power-on values the soft reset is checked against. Both datasheets
   --  give OSR = 0x02, but a BMP390 and a BMP388 both read 0x00 at power-on
   --  and after a soft reset (found on the bench, Ada-Device-Drivers), so
   --  either is accepted.
   Power_On_PWR_CTRL     : constant Unsigned_8 := 16#00#;
   Power_On_OSR          : constant Unsigned_8 := 16#00#;
   Datasheet_OSR_Default : constant Unsigned_8 := 16#02#;

   Calib_Data_Len : constant := 21;
   Data_Len       : constant := 6;

   --  timing
   Reset_Settle_Ms  : constant := 2;   --  before polling cmd_rdy
   Reset_Poll_Limit : constant := 20;  --  polls, 1 ms apart

   ---------------------------------------------------------------------
   --  Trim registers and fixed point results
   ---------------------------------------------------------------------

   --  Factory trim registers as the chip stores them (DS Table 24), before
   --  any scaling.
   subtype Trim_U16 is Integer range 0 .. 2**16 - 1;
   subtype Trim_S16 is Integer range -2**15 .. 2**15 - 1;
   subtype Trim_S8  is Integer range -2**7 .. 2**7 - 1;

   type Trim_Registers is record
      Par_T1, Par_T2 : Trim_U16 := 0;
      Par_T3         : Trim_S8  := 0;
      Par_P1, Par_P2 : Trim_S16 := 0;
      Par_P3, Par_P4 : Trim_S8  := 0;
      Par_P5, Par_P6 : Trim_U16 := 0;
      Par_P7, Par_P8 : Trim_S8  := 0;
      Par_P9         : Trim_S16 := 0;
      Par_P10        : Trim_S8  := 0;
      Par_P11        : Trim_S8  := 0;
   end record;

   --  compensation results: 0.01 Pa and 0.01 degree C, truncated toward 0
   type Centi_Pascal  is new Integer_64;
   type Centi_Celsius is new Integer_32;

   type Fixed_Reading is record
      Pressure    : Centi_Pascal  := 0;
      Temperature : Centi_Celsius := 0;
   end record;

   --  a raw ADC sample, 24 bits as assembled from DATA_0 .. DATA_5
   subtype Raw_Sample is Unsigned_32 range 0 .. 16#FF_FFFF#;

   --  Returns three bytes, low byte first, as one 24-bit value.
   function To_U24 (Lo, Mid, Hi : Storage_Element) return Raw_Sample is
     (Raw_Sample (Lo) + Raw_Sample (Mid) * 2**8 + Raw_Sample (Hi) * 2**16);

end BMP3XX_Types;
