--  logger_pre_launch.adb

package body Logger_Pre_Launch is

   Ring_Size : constant := 256;

   --  A modular index wraps by itself: 255 + 1 is 0.
   type Ring_Index is mod Ring_Size;
   type Sample_Ring is array (Ring_Index) of Telemetry.Sample;

   Ring  : Sample_Ring;
   Next  : Ring_Index := 0;  --  slot the next sample goes in
   Count : Natural    := 0;  --  samples held, up to Ring_Size

   procedure Remember (S : Telemetry.Sample) is
   begin
      Ring (Next) := S;
      Next := Next + 1;
      if Count < Ring_Size then
         Count := Count + 1;
      end if;
   end Remember;

   procedure Take_Oldest (S : out Telemetry.Sample; Got : out Boolean) is
   begin
      Got := Count > 0;
      if not Got then
         S := (others => <>);
         return;
      end if;

      --  the oldest is Count slots behind the next free one
      S := Ring (Next - Ring_Index'Mod (Count));
      Count := Count - 1;
   end Take_Oldest;

end Logger_Pre_Launch;
