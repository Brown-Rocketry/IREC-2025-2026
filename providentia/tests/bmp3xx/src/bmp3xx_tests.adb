--  bmp3xx_tests.adb
--  Host tests for the bmp3xx chip crate.
--
--  General plan:
--  1. Compensation against the Ada-Device-Drivers reference vectors (one
--     captured BMP390 trim block plus synthetic extremes), with the same
--     tolerances.
--  2. The settings checks, which don't touch the bus.
--  3. Init, Read and the faults real chips have shown, against
--     Fake_BMP3XX, once through BMP3XX_I2C_Bus and once through
--     BMP3XX_SPI_Bus. The driver is the same code both times.
--  Prints one line per check and exits with status 1 if any failed.

with Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Interfaces;  use Interfaces;
with System.Storage_Elements;

with Baro_Types;
with BMP3XX_Compensation; use BMP3XX_Compensation;
with BMP3XX;
with BMP3XX_I2C_Bus;
with BMP3XX_SPI_Bus;
with BMP3XX_Reference_Data; use BMP3XX_Reference_Data;
with BMP3XX_Types; use BMP3XX_Types;
with Fake_BMP3XX;

procedure BMP3XX_Tests is

   use type Baro_Types.Reading;
   use type System.Storage_Elements.Storage_Array;

   package I2C_Bus is new BMP3XX_I2C_Bus
     (Driver_Write_Read => Fake_BMP3XX.Write_Read,
      Driver_Write      => Fake_BMP3XX.Write,
      I2C_Address       => Fake_BMP3XX.Address);

   package I2C_Chip is new BMP3XX
     (Read_Registers   => I2C_Bus.Read_Registers,
      Write_Register   => I2C_Bus.Write_Register,
      Expected_Chip_ID => BMP390_Chip_ID,
      Delay_Ms         => Fake_BMP3XX.Delay_Ms);

   package SPI_Bus is new BMP3XX_SPI_Bus
     (Spi_Write   => Fake_BMP3XX.Spi_Write,
      Spi_Read    => Fake_BMP3XX.Spi_Read,
      Select_Chip => Fake_BMP3XX.Select_Chip,
      Release     => Fake_BMP3XX.Release);

   package SPI_Chip is new BMP3XX
     (Read_Registers   => SPI_Bus.Read_Registers,
      Write_Register   => SPI_Bus.Write_Register,
      Expected_Chip_ID => BMP390_Chip_ID,
      Delay_Ms         => Fake_BMP3XX.Delay_Ms);

   --  the settings checks don't use the bus, so either instance will do
   package Chip renames I2C_Chip;

   --  the flight setting, from Payload.Baro_Settings
   Flight : constant Baro_Types.Baro_Config :=
     (Pressure_OSR    => Baro_Types.X8,
      Temperature_OSR => Baro_Types.X1,
      Rate_Hz         => 50,
      Filter_On       => False);

   Failures : Natural := 0;

   procedure Check (Passed : Boolean; Name : String) is
   begin
      Put_Line ((if Passed then "  ok    " else "  FAIL  ") & Name);
      if not Passed then
         Failures := Failures + 1;
      end if;
   end Check;

   --  Run every reference vector through the integer compensation.
   procedure Reference_Vectors is
      Worst_T, Worst_P : Long_Float := 0.0;
      Bad : Natural := 0;
   begin
      for V of Vectors loop
         declare
            F : constant Fixed_Reading :=
              Compensate (Parse_Trim (Calibration_Blocks (V.Calibration_Index)),
                          V.Raw_Temperature, V.Raw_Pressure);
            T_Err : constant Long_Float :=
              abs (Long_Float (F.Temperature) / 100.0 - V.Temperature_C);
            P_Err : constant Long_Float :=
              abs (Long_Float (F.Pressure) / 100.0 - V.Pressure_Pa);
         begin
            Worst_T := Long_Float'Max (Worst_T, T_Err);
            Worst_P := Long_Float'Max (Worst_P, P_Err);
            if T_Err > V.Fixed_Temperature_Tol_C
              or else P_Err > V.Fixed_Pressure_Tol_Pa
            then
               Bad := Bad + 1;
            end if;
         end;
      end loop;
      Check (Bad = 0, "compensation, all" & Vectors'Length'Image
             & " reference vectors within tolerance");
      Put_Line ("        worst:" & Worst_T'Image & " C," & Worst_P'Image & " Pa");
   end Reference_Vectors;

   --  the captured trim block and a sea-level-ish physical vector
   Trim : constant Trim_Block := Calibration_Blocks (1);
   V1   : Vector renames Vectors (Physical_Vector_Count / 2);

   --  Init, Read and the faults, over one bus. Bus_Ok is checked at the end.
   generic
      with package Chip is new BMP3XX (<>);
      Bus : String;
      with function Bus_Ok return Boolean;
   procedure Driver_Checks;

   procedure Driver_Checks is
      R  : Baro_Types.Reading;
      F  : Fixed_Reading;
      Ok : Boolean;

      procedure Check (Passed : Boolean; Name : String) is
      begin
         BMP3XX_Tests.Check (Passed, Bus & ": " & Name);
      end Check;
   begin
      --  before Init
      Fake_BMP3XX.Power_On (BMP390_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature);
      Chip.Read (R, Ok);
      Check (not Ok and then R.Pressure = 0, "Read before Init is refused");
      Check (Chip.Compensate ((V1.Raw_Pressure, V1.Raw_Temperature))
               = (Pressure => 0, Temperature => 0),
             "Compensate before Init gives zero");
      Check (not Chip.Data_Ready, "Data_Ready before Init is False");

      --  normal bring-up
      Check (Chip.Check_Id, "Check_Id sees a BMP390");
      Chip.Init (Flight, Ok);
      Check (Ok, "Init with the flight setting");
      Check (Fake_BMP3XX.Reg (REG_OSR) = 16#03#, "OSR written as X8 / X1");
      Check (Fake_BMP3XX.Reg (REG_ODR) = 2, "ODR written as 50 Hz");
      Check (Fake_BMP3XX.Reg (REG_CONFIG) = 0, "IIR filter off");
      Check (Fake_BMP3XX.Reg (REG_PWR_CTRL) = 16#33#,
             "PWR_CTRL normal mode, both enabled");

      Chip.Read_Fixed (F, Ok);
      Check (Ok and then abs (Long_Float (F.Pressure) / 100.0 - V1.Pressure_Pa)
                           <= V1.Fixed_Pressure_Tol_Pa,
             "Read_Fixed matches the reference vector");
      Chip.Read (R, Ok);
      Check (Ok and then abs (Long_Float (Baro_Types.To_Pa (R.Pressure))
                              - V1.Pressure_Pa) <= 0.02,
             "Read in 1/64 Pa within 0.02 Pa of the reference");
      Check (abs (Long_Float (Baro_Types.To_C (R.Temperature))
                  - V1.Temperature_C) <= 0.011,
             "Read temperature within 0.011 C of the reference");

      declare
         Raw : Baro_Types.Raw_Reading;
      begin
         Chip.Read_Raw (Raw, Ok);
         Check (Ok and then Raw.Pressure = V1.Raw_Pressure
                and then Raw.Temperature = V1.Raw_Temperature,
                "Read_Raw returns the chip's ADC values unchanged");
         Check (Chip.Compensate (Raw) = R,
                "Compensate of the raw values matches Read");
      end;

      declare
         Cal : Baro_Types.Calibration_Blob;
      begin
         Chip.Read_Calibration (Cal, Ok);
         Check (Ok and then Cal.Length = 21
                and then Cal.Data (1 .. 21) = Trim,
                "Read_Calibration returns the 21 trim bytes");
      end;

      --  faults
      Fake_BMP3XX.Power_On (BMP388_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature);
      Chip.Init (Flight, Ok);
      Check (not Ok, "a BMP388 is refused by a BMP390 instance");

      Fake_BMP3XX.Power_On (BMP390_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature, Fake_BMP3XX.Ignores_Mode);
      Chip.Init (Flight, Ok);
      Check (not Ok, "a chip that ignores the mode write fails Init");
      Chip.Read (R, Ok);
      Check (not Ok, "and Read stays refused after a failed Init");

      Fake_BMP3XX.Power_On (BMP390_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature, Fake_BMP3XX.Never_Ready);
      Chip.Init (Flight, Ok);
      Check (not Ok, "a chip that never produces data fails Init");

      Fake_BMP3XX.Power_On (BMP390_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature, Fake_BMP3XX.Never_Resets);
      Chip.Init (Flight, Ok);
      Check (not Ok, "a chip that doesn't finish its reset fails Init");

      Fake_BMP3XX.Power_On (BMP390_Chip_ID, Trim, V1.Raw_Pressure,
                            V1.Raw_Temperature);
      Chip.Init ((Baro_Types.X32, Baro_Types.X32, 50, False), Ok);
      Check (not Ok and then Fake_BMP3XX.Reg (REG_PWR_CTRL) = 0,
             "settings that don't fit are refused before the chip starts");

      Check (Bus_Ok, "every transfer framed by chip select");
   end Driver_Checks;

   function No_Cs return Boolean is (True);

   procedure I2C_Checks is new Driver_Checks (I2C_Chip, "i2c", No_Cs);
   procedure SPI_Checks is new Driver_Checks
     (SPI_Chip, "spi", Fake_BMP3XX.Spi_Clean);

begin
   Put_Line ("bmp3xx host tests");
   Reference_Vectors;

   --  settings
   Check (Chip.ODR_Code (200) = 0, "ODR 200 Hz is code 0");
   Check (Chip.ODR_Code (50) = 2, "ODR 50 Hz is code 2");
   Check (Chip.ODR_Code (60) = 2, "ODR 60 Hz rounds down to 50 Hz");
   Check (Chip.ODR_Code (1) = 8, "ODR 1 Hz rounds down to 0.78 Hz");
   Check (Chip.ODR_Code (1_000) = 0, "ODR above 200 Hz is 200 Hz");
   Check (Chip.Conversion_Time_Us (Flight) = 18_969,
          "flight setting converts in 18969 us");
   Check (Chip.Settings_Fit (Flight), "flight setting fits 50 Hz");
   Check (not Chip.Settings_Fit
            ((Baro_Types.X32, Baro_Types.X2, 50, False)),
          "X32 pressure at 50 Hz is refused");
   Check (not Chip.Settings_Fit
            ((Baro_Types.X8, Baro_Types.X1, 200, False)),
          "flight oversampling at 200 Hz is refused (terrarium_pico)");

   --  unit conversion edges
   Check (Chip.To_Reading ((Pressure => -5, Temperature => 0)).Pressure = 0,
          "negative pressure holds at 0");
   Check (Chip.To_Reading ((Pressure => 100_000_000, Temperature => 0))
            .Pressure = Baro_Types.Pressure_Count'Last,
          "pressure above 262 kPa holds at the maximum");
   Check (Chip.To_Reading ((Pressure => 0, Temperature => -40_000))
            .Temperature = Integer_16'First,
          "temperature below -327 C holds at the minimum");
   Check (Chip.To_Reading ((Pressure => 10_132_500, Temperature => 2_500))
            = (Pressure => 6_484_800, Temperature => 2_500),
          "101325.00 Pa, 25.00 C converts exactly");

   I2C_Checks;
   SPI_Checks;

   New_Line;
   if Failures = 0 then
      Put_Line ("all passed");
   else
      Put_Line (Failures'Image & " failed");
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end BMP3XX_Tests;
