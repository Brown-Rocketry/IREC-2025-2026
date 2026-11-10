--  bmp3xx_spi_bus.ads
--  BMP3xx register access over 4-wire SPI. Part of the bmp3xx chip crate.
--  Gives BMP3XX the two register procedures it takes as formals.
--
--  General plan:
--  Each access is one chip select window. A read sends the register
--  address with bit 7 set, then clocks in one dummy byte before the data
--  (DS 5.3.2; the BMP280 had no dummy byte, the BMP3xx does). A write sends
--  the address with bit 7 clear, then the value.
--
--  The chip powers up on I2C and switches to SPI at the first falling edge
--  of CSB, until it loses power (DS 5.1). The first access here pulses CS
--  once on its own first, so the CHIP_ID read in Init is already on SPI.
--
--  The bus formals match Spi_Interface.Write and .Read, so Board.Spi_1's
--  go straight in. Chip select comes in as two procedures rather than a
--  pin, so this crate never names a GPIO type. Open the bus in mode 0 or 3,
--  at most 10 MHz.
--
--     package Baro_Bus is new BMP3XX_SPI_Bus
--       (Spi_Write   => Board.Spi_1.Write,
--        Spi_Read    => Board.Spi_1.Read,
--        Select_Chip => Baro_Cs_Low,
--        Release     => Baro_Cs_High);
--
--  Reference: BMP390 datasheet BST-BMP390-DS002, 5.1 (interface
--             selection), 5.3 (SPI)

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

generic
   with procedure Spi_Write (Buf : Storage_Array);
   with procedure Spi_Read (Buf : out Storage_Array);

   --  drive this chip's CS low, and back high
   with procedure Select_Chip;
   with procedure Release;
package BMP3XX_SPI_Bus is

   --  Read Data'Length registers starting at Reg.
   procedure Read_Registers (Reg : Unsigned_8; Data : out Storage_Array);

   --  Write Value to register Reg.
   procedure Write_Register (Reg : Unsigned_8; Value : Unsigned_8);

end BMP3XX_SPI_Bus;
