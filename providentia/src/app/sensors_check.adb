--  sensors_check.adb
--  Bench tool. Checks every device and prints live readings over the
--  console. The first thing to run on a new board. Replaces
--  terrarium_pico's i2c_sensors, i2c_demo and spi_flash_test.
--
--  General plan:
--  Prints one line per startup check, each ending in "ok" or "FAIL", then
--  the IMU capabilities and scales and the baro calibration. Then every
--  0.5 s prints one line of readings:
--     t_ms     milliseconds since boot
--     accel    raw counts X Y Z, then magnitude in milli-g
--     gyro     raw counts X Y Z
--     p_pa     pressure in pascals
--     t_cC     temperature in hundredths of a degree C
--     alt_cm   altitude above the first reading, in centimeters
--     armed    arm jumper, 1 or 0
--     batt_mV  battery, 0 until the ADC exists
--  At rest the accel magnitude should read about 1000 mg. That checks the
--  scale against gravity, which caught the LSM9DS1's real range on the
--  Pico.
--
--  Readings are compensated by the chip crate. The calibration line is for
--  checking the chip, not for decoding the log.

with Ada.Real_Time; use Ada.Real_Time;
with System.Storage_Elements; use System.Storage_Elements;

with Baro_Types;
with Console_Text;  use Console_Text;
with Imu_Types;     use Imu_Types;
with Payload;

procedure Sensors_Check is

   Period : constant Time_Span := Milliseconds (500);

   --  Print "<label>ok" or "<label>FAIL".
   procedure Put_Check (Label : String; Passed : Boolean) is
   begin
      Put (Label);
      Put_Line (if Passed then "ok" else "FAIL");
   end Put_Check;

   procedure Put_Vector (V : Raw_Vector) is
   begin
      for A in Axis loop
         Put (" ");
         Put_Int (Integer (V (A)));
      end loop;
   end Put_Vector;

   --  Print the IMU's capabilities and the scales at Imu_Settings.
   procedure Put_Imu_Info is
      Caps : constant Imu_Caps := Payload.Imu.Capabilities;
   begin
      Put ("imu fifo samples: ");
      Put_Int (Caps.Fifo_Samples);
      New_Line;
      Put ("imu accel counts/g: ");
      Put_Int (Integer (Payload.Imu.Accel_Counts_Per_G));
      New_Line;
      Put ("imu gyro counts/dps: ");
      Put_Int (Integer (Payload.Imu.Gyro_Counts_Per_Dps));
      New_Line;
   end Put_Imu_Info;

   --  Print the baro factory calibration as hex.
   procedure Put_Calibration is
      Cal : Baro_Types.Calibration_Blob;
      Ok  : Boolean;
   begin
      Payload.Baro.Read_Calibration (Cal, Ok);
      if Ok then
         Put ("baro calibration: ");
         Put_Hex (Cal.Data (1 .. Storage_Offset (Cal.Length)));
         New_Line;
      else
         Put_Line ("baro calibration: FAIL");
      end if;
   end Put_Calibration;

   Checks    : Payload.Check_Result;
   Accel     : Raw_Vector;
   Gyro      : Raw_Vector;
   Baro      : Baro_Types.Reading;
   P_Pa      : Float;
   First_Pa  : Float := 0.0;    --  altitude reference
   Have_Ref  : Boolean := False;
   Accel_Ok  : Boolean;
   Gyro_Ok   : Boolean;
   Baro_Ok   : Boolean;
   Next      : Time;

begin
   Payload.Initialize (Checks);
   Put_Line ("providentia sensors_check");
   Put_Check ("flash id:  ", Checks.Flash);
   Put_Check ("imu id:    ", Payload.Imu.Check_Id);
   Put_Check ("imu setup: ", Checks.Imu);
   Put_Check ("baro id:   ", Payload.Baro.Check_Id);
   Put_Check ("baro setup: ", Checks.Baro);

   if Checks.Imu then
      Put_Imu_Info;
   end if;
   if Checks.Baro then
      Put_Calibration;
   end if;

   Put_Line
     ("t_ms accel_x accel_y accel_z accel_mg gyro_x gyro_y gyro_z"
      & " p_pa t_cC alt_cm armed batt_mV");

   Next := Clock;
   loop
      Payload.Imu.Read_Accel (Accel, Accel_Ok);
      Payload.Imu.Read_Gyro (Gyro, Gyro_Ok);
      Payload.Baro.Read (Baro, Baro_Ok);

      Put_Int (Integer (Payload.Clock_Ms));

      --  failed reads print zeros, the same as the logger records them
      Put_Vector (Accel);
      Put (" ");
      Put_Int
        (Integer (1000.0
           * Payload.Flight.Magnitude
               (Float (Accel (X)), Float (Accel (Y)), Float (Accel (Z)))
           / Payload.Imu.Accel_Counts_Per_G));
      Put_Vector (Gyro);

      if Baro_Ok then
         P_Pa := Baro_Types.To_Pa (Baro.Pressure);
         if not Have_Ref then
            First_Pa := P_Pa;
            Have_Ref := True;
         end if;
         Put (" ");
         Put_Int (Integer (P_Pa));
         Put (" ");
         Put_Int (Integer (Baro.Temperature));  --  already 1/100 C
         Put (" ");
         Put_Int (Integer (100.0
           * Payload.Flight.Pressure_Altitude_M (P_Pa, First_Pa)));
      else
         Put (" 0 0 0");
      end if;

      Put (if Payload.Armed then " 1 " else " 0 ");
      Put_Int (Integer (Payload.Battery_mV));

      if not (Accel_Ok and Gyro_Ok and Baro_Ok) then
         Put (" read_fail");
      end if;
      New_Line;

      Next := Next + Period;
      delay until Next;
   end loop;
end Sensors_Check;
