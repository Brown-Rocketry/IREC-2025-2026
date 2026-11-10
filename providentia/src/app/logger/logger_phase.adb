--  logger_phase.adb

with Baro_Types;
with Logger_Health;
with Telemetry;

package body Logger_Phase is

   package Flight  renames Payload.Flight;
   package Journal renames Payload.Journal;

   use type Flight.Phase;

   Machine : Flight.Machine;

   procedure Start is
   begin
      Flight.Reset (Machine);
   end Start;

   procedure Resume is
      Info     : Journal.Log_Info;
      Header   : Telemetry.Header;
      Last_Pad : Telemetry.Sample;
      Ground   : Baro_Types.Reading;
      Found    : Boolean;
      Ok       : Boolean;
   begin
      Flight.Reset (Machine);
      Journal.Inspect (Info, Header, Ok);
      if not Ok or else Info.Last_Phase <= Flight.Pad then
         return;
      end if;

      Journal.Find_Last_Record (Flight.Pad, Last_Pad, Found);
      if not Found then
         --  no pad pressure to measure from, so altitude starts from here
         Logger_Health.Count_Error;
         return;
      end if;

      --  the log holds raw values; compensate with this chip's calibration
      Ground := Payload.Baro.Compensate
        ((Pressure    => Last_Pad.Pressure,
          Temperature => Last_Pad.Temperature));
      Flight.Resume
        (Machine, Info.Last_Phase, Baro_Types.To_Pa (Ground.Pressure),
         Payload.Clock_Ms);
   end Resume;

   procedure Update (Batch : Logger_Sensors.Imu_Batch; Count : Natural) is
      Changed : Boolean;
   begin
      if Flight.Current (Machine) = Flight.Idle then
         if Payload.Armed and then Logger_Sensors.Have_Baro then
            Flight.Arm
              (Machine, Payload.Clock_Ms, Logger_Sensors.Pressure_Pa);
         end if;
      elsif Flight.Current (Machine) = Flight.Pad
        and then not Payload.Armed
      then
         Flight.Disarm (Machine);
      end if;

      if Count > 0 and then Logger_Sensors.Have_Baro then
         Flight.Step
           (Machine, Payload.Clock_Ms,
            Logger_Sensors.Mean_Accel_G (Batch, Count),
            Logger_Sensors.Pressure_Pa, Changed);
      end if;
   end Update;

   function Current return Flight.Phase is (Flight.Current (Machine));

end Logger_Phase;
