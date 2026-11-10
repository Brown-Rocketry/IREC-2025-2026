--  logger_timing.ads
--  The fixed 10 ms period of the logging loop. Part of flight_logger.
--
--  General plan:
--  Each deadline is the previous one plus the period, not "now" plus the
--  period, so variation in the work doesn't build up as drift. That drift
--  is what took terrarium_pico from 6.6 Hz toward 5 Hz: it slept a flat
--  6 ms after work of varying length. If a deadline has already passed,
--  the miss is counted and timing restarts from now, rather than running
--  ticks back to back to catch up.

with Interfaces; use Interfaces;

package Logger_Timing is

   Tick_Us : constant := 10_000;  --  100 Hz loop

   --  Set the first deadline one period from now.
   procedure Start;

   --  Wait until the next deadline, and count the tick.
   procedure Wait_For_Next_Tick;

   --  Returns the number of ticks since Start.
   function Ticks return Unsigned_32;

end Logger_Timing;
