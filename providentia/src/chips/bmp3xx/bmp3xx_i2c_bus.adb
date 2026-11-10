--  bmp3xx_i2c_bus.adb

package body BMP3XX_I2C_Bus is

   procedure Read_Registers (Reg : Unsigned_8; Data : out Storage_Array) is
   begin
      Driver_Write_Read
        (I2C_Address, (1 => Storage_Element (Reg)), Data);
   end Read_Registers;

   procedure Write_Register (Reg : Unsigned_8; Value : Unsigned_8) is
   begin
      Driver_Write
        (I2C_Address, (Storage_Element (Reg), Storage_Element (Value)));
   end Write_Register;

end BMP3XX_I2C_Bus;
