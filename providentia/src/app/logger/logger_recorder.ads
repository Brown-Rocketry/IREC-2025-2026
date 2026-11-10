--  logger_recorder.ads
--  Which samples go into the journal, and when pages are closed. Part of
--  flight_logger.
--
--  General plan:
--  Each IMU sample becomes a record with the latest raw baro reading, and
--  is logged if it's due in the current phase:
--     Idle     nothing, so bench time costs no flash
--     Pad      every 833rd sample, about 1 Hz
--     Boost    every sample, 833 Hz
--     Coast    every sample
--     Descent  every 16th sample, about 52 Hz
--     Landed   nothing; the last page is written on touchdown
--  On the pad every sample also goes into Logger_Pre_Launch, which is
--  logged when boost is detected.
--
--  Each page holds one phase: on a phase change the partly filled page is
--  written first. A record no newer than the last one logged is skipped,
--  because the pre-launch buffer overlaps the last pad record, and the
--  journal would read a backward step as a timestamp wrap.

with Payload;
with Telemetry;

package Logger_Recorder is

   --  IMU samples per logged sample, by Flight.Phase'Pos; 0 = not logged.
   --  Also written to the journal header.
   Log_Every : constant Telemetry.Decimation_Table :=
     (0 => 0,      --  Idle
      1 => 833,    --  Pad
      2 => 1,      --  Boost
      3 => 1,      --  Coast
      4 => 16,     --  Descent
      5 => 0);     --  Landed

   --  Start in Phase, after a fresh start or a resume.
   procedure Start (Phase : Payload.Flight.Phase);

   --  Returns the phase of the page being filled.
   function Phase return Payload.Flight.Phase;

   --  If New_Phase differs from Phase, close the page and switch. Moving
   --  from Pad to Boost also logs the pre-launch buffer.
   procedure Change_Phase (New_Phase : Payload.Flight.Phase);

   --  Hand the journal this tick's trailer values.
   procedure Update_Status;

   --  Log S if it's due in this phase, and keep it on the pad.
   procedure Offer (S : Telemetry.Sample);

   --  Returns True once the flash is full and logging has stopped.
   function Is_Full return Boolean;

   --  Stop logging: the journal reported Full at open.
   procedure Set_Full;

end Logger_Recorder;
