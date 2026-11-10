--  logger_sensors.adb

with Interfaces; use Interfaces;

with Imu_Types; use Imu_Types;
with Logger_Health;
with Logger_Timing;
with Payload;

package body Logger_Sensors is

   Baro_Interval : constant := 2;  --  ticks between baro reads

   Raw          : Baro_Types.Raw_Reading;
   Pressure     : Float := 0.0;
   Have         : Boolean := False;
   Counts_Per_G : Float := 1.0;

   procedure Start is
   begin
      Counts_Per_G := Payload.Imu.Accel_Counts_Per_G;
   end Start;

   procedure Read_Baro_If_Due is
      R  : Baro_Types.Raw_Reading;
      Ok : Boolean;
   begin
      if Logger_Timing.Ticks mod Baro_Interval /= 0 then
         return;
      end if;

      Payload.Baro.Read_Raw (R, Ok);
      if Ok then
         Raw      := R;
         Pressure := Baro_Types.To_Pa (Payload.Baro.Compensate (R).Pressure);
         Have     := True;
      else
         Logger_Health.Count_Error;
      end if;
   end Read_Baro_If_Due;

   procedure Read_Imu (Batch : out Imu_Batch; Count : out Natural) is
      Ok : Boolean;
   begin
      Payload.Imu.Read_Batch (Batch, Count, Ok);
      if not Ok then
         Logger_Health.Count_Error;
      end if;
   end Read_Imu;

   function Have_Baro return Boolean is (Have);
   function Baro_Raw return Baro_Types.Raw_Reading is (Raw);
   function Pressure_Pa return Float is (Pressure);

   function Mean_Accel_G (Batch : Imu_Batch; Count : Positive) return Float
   is
      Sum : Float := 0.0;
   begin
      for I in 1 .. Count loop
         Sum := Sum + Payload.Flight.Magnitude
           (Float (Batch (I).Accel (X)),
            Float (Batch (I).Accel (Y)),
            Float (Batch (I).Accel (Z)));
      end loop;
      return Sum / Float (Count) / Counts_Per_G;
   end Mean_Accel_G;

end Logger_Sensors;
