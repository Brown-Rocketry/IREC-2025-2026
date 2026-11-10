--  bmp3xx.adb

with BMP3XX_Compensation;

package body BMP3XX is

   Max_ODR_Code : constant := 17;  --  0.0015 Hz

   Trim       : Trim_Registers;
   Calib_Raw  : Storage_Array (1 .. Calib_Data_Len) := (others => 0);
   Have_Trim  : Boolean := False;  --  Trim and Calib_Raw are valid
   Configured : Boolean := False;  --  Init finished, chip is measuring

   ---------------------------------------------------------------------
   --  Register access
   ---------------------------------------------------------------------

   procedure Read_Regs (Reg : Unsigned_8; Data : out Storage_Array)
     renames Read_Registers;

   function Read_Reg (Reg : Unsigned_8) return Unsigned_8 is
      Buf : Storage_Array (1 .. 1);
   begin
      Read_Regs (Reg, Buf);
      return Unsigned_8 (Buf (1));
   end Read_Reg;

   procedure Write_Reg (Reg : Unsigned_8; Value : Unsigned_8)
     renames Write_Register;

   ---------------------------------------------------------------------
   --  Settings
   ---------------------------------------------------------------------

   --  output period in microseconds for an ODR code: 5 ms doubling
   function Period_Us (Code : Natural) return Integer_64 is
     (5_000 * 2**Code)
     with Pre => Code <= Max_ODR_Code;

   function ODR_Code (Rate_Hz : Positive) return Natural is
      Code : Natural := 0;
   begin
      --  slow down until the rate is at or below the request, which means
      --  the period is at least 1 s / Rate_Hz
      while Code < Max_ODR_Code
        and then Period_Us (Code) * Integer_64 (Rate_Hz) < 1_000_000
      loop
         Code := Code + 1;
      end loop;
      return Code;
   end ODR_Code;

   function Conversion_Time_Us (Cfg : Baro_Types.Baro_Config) return Natural
   is
      P_Steps : constant Natural :=
        2**Baro_Types.Oversampling'Pos (Cfg.Pressure_OSR);
      T_Steps : constant Natural :=
        2**Baro_Types.Oversampling'Pos (Cfg.Temperature_OSR);
   begin
      --  DS 3.9.2, with pressure and temperature both enabled
      return 234 + (392 + P_Steps * 2_020) + (163 + T_Steps * 2_020);
   end Conversion_Time_Us;

   function Settings_Fit (Cfg : Baro_Types.Baro_Config) return Boolean is
     (Integer_64 (Conversion_Time_Us (Cfg))
      < Period_Us (ODR_Code (Cfg.Rate_Hz)));

   --  OSR register: osr_p bits 2:0, osr_t bits 5:3 (DS 4.3.18)
   function OSR_Value (Cfg : Baro_Types.Baro_Config) return Unsigned_8 is
     (Unsigned_8 (Baro_Types.Oversampling'Pos (Cfg.Pressure_OSR))
      or Shift_Left
           (Unsigned_8 (Baro_Types.Oversampling'Pos (Cfg.Temperature_OSR)),
            3));

   --  CONFIG register: iir_filter bits 3:1 (DS 4.3.21). On uses
   --  coefficient 3, the lightest setting, to keep the apogee lag small.
   function Config_Value (Cfg : Baro_Types.Baro_Config) return Unsigned_8 is
     (if Cfg.Filter_On then Shift_Left (2, 1) else 0);

   ---------------------------------------------------------------------
   --  Steps of Init
   ---------------------------------------------------------------------

   --  Soft reset, wait for cmd_rdy, then check the register file is back
   --  at its power-on values. A read can fail while the chip resets, so
   --  only the poll count bounds the wait.
   procedure Soft_Reset (Ok : out Boolean) is
      Status : Unsigned_8 := 0;
      Regs   : Storage_Array (1 .. 2);  --  PWR_CTRL, OSR
   begin
      Write_Reg (REG_CMD, CMD_SOFTRESET);
      Delay_Ms (Reset_Settle_Ms);

      for Attempt in 1 .. Reset_Poll_Limit loop
         Status := Read_Reg (REG_STATUS);
         exit when (Status and STATUS_CMD_RDY_Msk) /= 0;
         Delay_Ms (1);
      end loop;

      if (Status and STATUS_CMD_RDY_Msk) = 0 then
         Ok := False;
         return;
      end if;

      --  PWR_CTRL (0x1B) and OSR (0x1C) are next to each other
      Read_Regs (REG_PWR_CTRL, Regs);
      Ok := Unsigned_8 (Regs (1)) = Power_On_PWR_CTRL
        and then (Unsigned_8 (Regs (2)) = Power_On_OSR
                  or else Unsigned_8 (Regs (2)) = Datasheet_OSR_Default);
   end Soft_Reset;

   --  Returns True if both drdy flags are set.
   function Both_Ready return Boolean is
      Both : constant Unsigned_8 :=
        STATUS_DRDY_PRESS_Msk or STATUS_DRDY_TEMP_Msk;
   begin
      return (Read_Reg (REG_STATUS) and Both) = Both;
   end Both_Ready;

   --  Wait for a fresh result after configuring. Reading the data first
   --  clears the ready flags, so a set flag afterward is new.
   procedure Wait_For_Fresh_Data
     (Cfg : Baro_Types.Baro_Config; Ok : out Boolean)
   is
      Discard : Storage_Array (1 .. Data_Len);
      Wait_Ms : constant Natural :=
        Natural (2 * Period_Us (ODR_Code (Cfg.Rate_Hz)) / 1_000) + 10;
   begin
      Read_Regs (REG_DATA_0, Discard);
      for I in 1 .. Wait_Ms loop
         Delay_Ms (1);
         if Both_Ready then
            Ok := True;
            return;
         end if;
      end loop;
      Ok := False;
   end Wait_For_Fresh_Data;

   ---------------------------------------------------------------------
   --  Public
   ---------------------------------------------------------------------

   function Check_Id return Boolean is
     (Read_Reg (REG_CHIP_ID) = Expected_Chip_ID);

   procedure Init (Cfg : Baro_Types.Baro_Config; Ok : out Boolean) is
      Expected_Power : constant Unsigned_8 :=
        PWR_CTRL_PRESS_EN or PWR_CTRL_TEMP_EN or PWR_CTRL_NORMAL;
   begin
      Configured := False;
      Ok := False;

      if not Check_Id then
         return;
      end if;

      Soft_Reset (Ok);
      if not Ok then
         return;
      end if;

      Read_Regs (REG_CALIB_DATA, Calib_Raw);
      Trim := BMP3XX_Compensation.Parse_Trim (Calib_Raw);
      Have_Trim := True;

      --  refuse before writing anything, so the chip stays asleep
      if not Settings_Fit (Cfg) then
         Ok := False;
         return;
      end if;

      Write_Reg (REG_OSR, OSR_Value (Cfg));
      Write_Reg (REG_ODR, Unsigned_8 (ODR_Code (Cfg.Rate_Hz)));
      Write_Reg (REG_CONFIG, Config_Value (Cfg));
      Write_Reg (REG_PWR_CTRL, Expected_Power);

      --  the chip flags combinations it won't run
      if (Read_Reg (REG_ERR_REG) and (ERR_CONF_Msk or ERR_FATAL_Msk)) /= 0
      then
         Ok := False;
         return;
      end if;

      --  check the mode and enables actually took
      if (Read_Reg (REG_PWR_CTRL) and PWR_CTRL_Used_Msk) /= Expected_Power
      then
         Ok := False;
         return;
      end if;

      Wait_For_Fresh_Data (Cfg, Ok);
      Configured := Ok;
   end Init;

   function Data_Ready return Boolean is
     (Configured and then Both_Ready);

   procedure Read_Raw (R : out Baro_Types.Raw_Reading; Ok : out Boolean) is
      Buf : Storage_Array (0 .. Data_Len - 1);
   begin
      R  := (0, 0);
      Ok := Configured;
      if not Ok then
         return;
      end if;

      --  pressure then temperature, 3 bytes each, LSB first
      Read_Regs (REG_DATA_0, Buf);
      R := (Pressure    => To_U24 (Buf (0), Buf (1), Buf (2)),
            Temperature => To_U24 (Buf (3), Buf (4), Buf (5)));
   end Read_Raw;

   function Compensate_Fixed (Raw : Baro_Types.Raw_Reading)
     return Fixed_Reading is
     (if Have_Trim
      then BMP3XX_Compensation.Compensate
             (Trim,
              Uncomp_Temp  => Raw.Temperature,
              Uncomp_Press => Raw.Pressure)
      else (0, 0));

   procedure Read_Fixed (F : out Fixed_Reading; Ok : out Boolean) is
      Raw : Baro_Types.Raw_Reading;
   begin
      Read_Raw (Raw, Ok);
      F := (if Ok then Compensate_Fixed (Raw) else (0, 0));
   end Read_Fixed;

   function Compensate
     (Raw : Baro_Types.Raw_Reading) return Baro_Types.Reading is
     (To_Reading (Compensate_Fixed (Raw)));

   function To_Reading (F : Fixed_Reading) return Baro_Types.Reading is
      --  0.01 Pa to 1/64 Pa is * 64 / 100 = * 16 / 25, rounded
      P : constant Integer_64 :=
        (if F.Pressure <= 0 then 0
         else (Integer_64 (F.Pressure) * 16 + 12) / 25);
      T : constant Integer_32 := Integer_32 (F.Temperature);
   begin
      return
        (Pressure    =>
           (if P > Integer_64 (Baro_Types.Pressure_Count'Last)
            then Baro_Types.Pressure_Count'Last
            else Baro_Types.Pressure_Count (P)),
         Temperature =>
           (if T < Integer_32 (Integer_16'First) then Integer_16'First
            elsif T > Integer_32 (Integer_16'Last) then Integer_16'Last
            else Integer_16 (T)));
   end To_Reading;

   procedure Read (R : out Baro_Types.Reading; Ok : out Boolean) is
      F : Fixed_Reading;
   begin
      Read_Fixed (F, Ok);
      R := (if Ok then To_Reading (F) else (Pressure => 0, Temperature => 0));
   end Read;

   procedure Read_Calibration
     (Cal : out Baro_Types.Calibration_Blob;
      Ok  : out Boolean)
   is
   begin
      Cal := (Length => 0, Data => (others => 0));
      Ok  := Have_Trim;
      if Ok then
         Cal.Length := Calib_Data_Len;
         Cal.Data (1 .. Calib_Data_Len) := Calib_Raw;
      end if;
   end Read_Calibration;

end BMP3XX;
