--  fake_bmp3xx.ads
--  A BMP3xx register file in RAM, for host tests of BMP3XX over both bus
--  adapters. Behaves like the datasheet in the ways the driver relies on,
--  and can be told to misbehave the ways real chips have.
--
--  General plan:
--  Reads auto-increment from the register sent first. A soft reset puts
--  PWR_CTRL and OSR back to 0 and sets cmd_rdy. Reading DATA_0 clears the
--  ready flags; each Delay_Ms sets them again if the chip is measuring.
--  On SPI, bit 7 of the first byte marks a read, a read returns one junk
--  dummy byte first, and the chip ignores SPI until CS has gone low once
--  (DS 5.1), as it ignores everything after power on.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

with I2C_Types;

package Fake_BMP3XX is

   Address : constant I2C_Types.I2C_Address := 16#77#;

   --  ways the chip can misbehave
   type Fault is
     (None,
      Ignores_Mode,   --  PWR_CTRL writes are dropped: the frozen chip
      Never_Ready,    --  measures but never sets drdy
      Never_Resets);  --  cmd_rdy never comes back after a soft reset

   --  Power up with Chip_ID, the trim block and raw readings, and Fault.
   procedure Power_On
     (Chip_ID   : Unsigned_8;
      Trim      : Storage_Array;
      Raw_Press : Unsigned_32;
      Raw_Temp  : Unsigned_32;
      F         : Fault := None)
     with Pre => Trim'Length = 21;

   --  register value, for checks
   function Reg (R : Unsigned_8) return Unsigned_8;

   --  Returns True if every SPI transfer happened with CS low, and CS was
   --  released after each one.
   function Spi_Clean return Boolean;

   --  the I2C bus, passed to BMP3XX_I2C_Bus
   procedure Write_Read
     (Target : I2C_Types.I2C_Address;
      Tx_Buf : Storage_Array;
      Rx_Buf : out Storage_Array);
   procedure Write
     (Target : I2C_Types.I2C_Address;
      Buf    : Storage_Array);

   --  the SPI bus and chip select, passed to BMP3XX_SPI_Bus
   procedure Spi_Write (Buf : Storage_Array);
   procedure Spi_Read (Buf : out Storage_Array);
   procedure Select_Chip;
   procedure Release;

   --  the delay, passed to BMP3XX
   procedure Delay_Ms (Ms : Natural);

end Fake_BMP3XX;
