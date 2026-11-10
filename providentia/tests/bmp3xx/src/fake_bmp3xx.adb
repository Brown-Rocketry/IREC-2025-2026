--  fake_bmp3xx.adb

with BMP3XX_Types; use BMP3XX_Types;

package body Fake_BMP3XX is

   Regs : array (Unsigned_8) of Unsigned_8 := (others => 0);
   Mode : Fault := None;

   Drdy : constant Unsigned_8 := STATUS_DRDY_PRESS_Msk or STATUS_DRDY_TEMP_Msk;

   --  SPI state
   Junk : constant Storage_Element := 16#A5#;  --  the dummy byte

   type Spi_Phase is (Want_Address, Reading, Writing);

   Spi_Mode  : Boolean := False;  --  CS has gone low since power on
   Selected  : Boolean := False;
   Live      : Boolean := False;  --  this CS window is in SPI mode
   Phase     : Spi_Phase := Want_Address;
   Spi_Reg   : Unsigned_8 := 0;
   Dummy_Due : Boolean := False;
   Clean     : Boolean := True;

   --  Read registers from R on, as a burst read does.
   procedure Read_From (R : Unsigned_8; Buf : out Storage_Array) is
      Next : Unsigned_8 := R;
   begin
      if R = REG_DATA_0 then
         Regs (REG_STATUS) := Regs (REG_STATUS) and not Drdy;
      end if;
      for B of Buf loop
         B := Storage_Element (Regs (Next));
         Next := Next + 1;
      end loop;
   end Read_From;

   procedure Write_To (R : Unsigned_8; V : Unsigned_8) is
   begin
      if R = REG_CMD and then V = CMD_SOFTRESET then
         Regs (REG_PWR_CTRL) := Power_On_PWR_CTRL;
         Regs (REG_OSR)      := Power_On_OSR;
         Regs (REG_STATUS)   :=
           (if Mode = Never_Resets then 0 else STATUS_CMD_RDY_Msk);
      elsif R = REG_PWR_CTRL and then Mode = Ignores_Mode then
         null;
      else
         Regs (R) := V;
      end if;
   end Write_To;

   procedure Power_On
     (Chip_ID   : Unsigned_8;
      Trim      : Storage_Array;
      Raw_Press : Unsigned_32;
      Raw_Temp  : Unsigned_32;
      F         : Fault := None)
   is
      I : Unsigned_8 := REG_CALIB_DATA;
   begin
      Regs := (others => 0);
      Mode := F;
      --  Spi_Mode stays: on the board the MCU and the chip share a supply,
      --  so the adapter's CS pulse and the chip's power on go together
      Selected := False;
      Clean    := True;
      Regs (REG_CHIP_ID) := Chip_ID;
      Regs (REG_OSR)     := Datasheet_OSR_Default;
      Regs (REG_STATUS)  := STATUS_CMD_RDY_Msk;

      for B of Trim loop
         Regs (I) := Unsigned_8 (B);
         I := I + 1;
      end loop;

      --  pressure at DATA_0 .. 2, temperature at DATA_3 .. 5, LSB first
      for K in 0 .. 2 loop
         Regs (REG_DATA_0 + Unsigned_8 (K)) :=
           Unsigned_8 (Shift_Right (Raw_Press, 8 * K) and 16#FF#);
         Regs (REG_DATA_0 + 3 + Unsigned_8 (K)) :=
           Unsigned_8 (Shift_Right (Raw_Temp, 8 * K) and 16#FF#);
      end loop;
   end Power_On;

   function Reg (R : Unsigned_8) return Unsigned_8 is (Regs (R));

   function Spi_Clean return Boolean is (Clean and then not Selected);

   procedure Write_Read
     (Target : I2C_Types.I2C_Address;
      Tx_Buf : Storage_Array;
      Rx_Buf : out Storage_Array)
   is
      use type I2C_Types.I2C_Address;
   begin
      pragma Assert (Target = Address and then not Spi_Mode);
      Read_From (Unsigned_8 (Tx_Buf (Tx_Buf'First)), Rx_Buf);
   end Write_Read;

   procedure Write
     (Target : I2C_Types.I2C_Address;
      Buf    : Storage_Array)
   is
      use type I2C_Types.I2C_Address;
   begin
      pragma Assert (Target = Address and then not Spi_Mode
                     and then Buf'Length = 2);
      Write_To (Unsigned_8 (Buf (Buf'First)),
                Unsigned_8 (Buf (Buf'First + 1)));
   end Write;

   procedure Select_Chip is
   begin
      if Selected then
         Clean := False;
      end if;
      --  the falling edge that leaves I2C mode doesn't count as SPI
      Live      := Spi_Mode;
      Selected  := True;
      Spi_Mode  := True;
      Phase     := Want_Address;
      Dummy_Due := False;
   end Select_Chip;

   procedure Release is
   begin
      if not Selected then
         Clean := False;
      end if;
      Selected := False;
   end Release;

   procedure Spi_Write (Buf : Storage_Array) is
   begin
      if not Selected then
         Clean := False;
         return;
      elsif not Live then
         return;
      end if;
      for B of Buf loop
         case Phase is
            when Want_Address =>
               Spi_Reg := Unsigned_8 (B) and 16#7F#;
               if (Unsigned_8 (B) and 16#80#) /= 0 then
                  Phase     := Reading;
                  Dummy_Due := True;
               else
                  Phase := Writing;
               end if;
            when Writing =>
               --  one value per address byte (DS 5.3.1)
               Write_To (Spi_Reg, Unsigned_8 (B));
               Phase := Want_Address;
            when Reading =>
               null;  --  bytes clocked out during a read are ignored
         end case;
      end loop;
   end Spi_Write;

   procedure Spi_Read (Buf : out Storage_Array) is
   begin
      Buf := (others => Junk);
      if not Selected or else (Live and then Phase /= Reading) then
         Clean := False;
         return;
      elsif not Live then
         return;
      end if;
      if Dummy_Due then
         Dummy_Due := False;
         if Buf'Length > 1 then
            Read_From (Spi_Reg, Buf (Buf'First + 1 .. Buf'Last));
            Spi_Reg := Spi_Reg + Unsigned_8 (Buf'Length - 1);
         end if;
      else
         Read_From (Spi_Reg, Buf);
         Spi_Reg := Spi_Reg + Unsigned_8 (Buf'Length);
      end if;
   end Spi_Read;

   procedure Delay_Ms (Ms : Natural) is
   begin
      --  a measuring chip has new data after any wait
      if Ms > 0
        and then (Regs (REG_PWR_CTRL) and PWR_CTRL_NORMAL) = PWR_CTRL_NORMAL
        and then Mode /= Never_Ready
      then
         Regs (REG_STATUS) := Regs (REG_STATUS) or Drdy;
      end if;
   end Delay_Ms;

end Fake_BMP3XX;
