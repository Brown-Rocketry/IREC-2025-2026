--  bmp3xx_spi_bus.adb

package body BMP3XX_SPI_Bus is

   Read_Bit : constant Unsigned_8 := 16#80#;

   On_Spi : Boolean := False;  --  CS has gone low at least once

   --  Pulse CS before the first access, so the chip has left I2C mode.
   procedure Switch_To_Spi is
   begin
      if not On_Spi then
         Select_Chip;
         Release;
         On_Spi := True;
      end if;
   end Switch_To_Spi;

   procedure Read_Registers (Reg : Unsigned_8; Data : out Storage_Array) is
      --  dummy byte, then the data
      Buf : Storage_Array (0 .. Data'Length);
   begin
      Switch_To_Spi;
      Select_Chip;
      Spi_Write ((1 => Storage_Element (Reg or Read_Bit)));
      Spi_Read (Buf);
      Release;
      Data := Buf (1 .. Buf'Last);
   end Read_Registers;

   procedure Write_Register (Reg : Unsigned_8; Value : Unsigned_8) is
   begin
      Switch_To_Spi;
      Select_Chip;
      Spi_Write
        ((Storage_Element (Reg and not Read_Bit), Storage_Element (Value)));
      Release;
   end Write_Register;

end BMP3XX_SPI_Bus;
