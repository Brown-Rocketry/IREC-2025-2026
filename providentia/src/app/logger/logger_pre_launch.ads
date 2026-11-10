--  logger_pre_launch.ads
--  The last 256 samples on the pad, kept in RAM. Part of flight_logger.
--
--  General plan:
--  Boost is only declared after the acceleration has held for 100 ms, and
--  on the pad only about one sample a second is logged. So without this
--  buffer the start of the burn would be lost. On the pad every sample
--  goes in here, overwriting the oldest; when boost is detected the
--  recorder logs them all, oldest first. 256 samples is about 0.3 s at
--  833 Hz.

with Telemetry;

package Logger_Pre_Launch is

   --  Keep S, dropping the oldest sample when full.
   procedure Remember (S : Telemetry.Sample);

   --  Take the oldest sample still held. Got is False when empty.
   procedure Take_Oldest (S : out Telemetry.Sample; Got : out Boolean);

end Logger_Pre_Launch;
