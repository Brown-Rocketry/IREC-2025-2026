--  logger_health.ads
--  Counts of what went wrong while logging, for the page trailers. Part of
--  flight_logger.
--
--  General plan:
--  Two counts since boot, each stopping at its maximum instead of
--  wrapping, so a large number never turns back into a small one:
--     Missed  ticks whose deadline had already passed (a flash erase or a
--             slow bus stalled the loop)
--     Errors  failed sensor reads and flash writes

with Interfaces; use Interfaces;

package Logger_Health is

   procedure Count_Miss;
   procedure Count_Error;

   function Missed return Unsigned_16;
   function Errors return Unsigned_16;

end Logger_Health;
