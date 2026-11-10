--  bmp3xx_i2c_bus.ads
--  BMP3xx register access over I2C. Part of the bmp3xx chip crate. Gives
--  BMP3XX the two register procedures it takes as formals.
--
--  General plan:
--  A read writes the register address, then reads with a repeated start;
--  the chip auto-increments. A write sends the address and the value in
--  one transfer. The bus formals match I2C_Interface.Write_Read and .Write,
--  so Board.I2C_1's go straight in.
--
--  Reference: BMP390 datasheet BST-BMP390-DS002, 5.2 (I2C)

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

with I2C_Types;

generic
   with procedure Driver_Write_Read
     (Target : I2C_Types.I2C_Address;
      Tx_Buf : Storage_Array;
      Rx_Buf : out Storage_Array);
   with procedure Driver_Write
     (Target : I2C_Types.I2C_Address;
      Buf    : Storage_Array);

   --  7-bit, BMP3XX_Types.I2C_Addr_SDO_Low or _High
   I2C_Address : I2C_Types.I2C_Address;
package BMP3XX_I2C_Bus is

   --  Read Data'Length registers starting at Reg.
   procedure Read_Registers (Reg : Unsigned_8; Data : out Storage_Array);

   --  Write Value to register Reg.
   procedure Write_Register (Reg : Unsigned_8; Value : Unsigned_8);

end BMP3XX_I2C_Bus;
