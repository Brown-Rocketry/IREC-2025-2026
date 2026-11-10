--  console_text.ads
--  Text over the board console (USART2, the ST-Link virtual COM port at
--  115200). For the bench tools only; flight_logger never prints, so
--  debug output can't slow down logging.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

package Console_Text is

   --  Send S. Retries until every byte is accepted, so a slow terminal
   --  doesn't truncate lines.
   procedure Put (S : String);

   --  Send S, then CR LF.
   procedure Put_Line (S : String);

   procedure New_Line;

   --  Send N in decimal, with no leading space.
   procedure Put_Int (N : Integer);

   --  Send each byte as two uppercase hex digits, with no separators.
   procedure Put_Hex (Data : Storage_Array);

   --  Send B as two uppercase hex digits.
   procedure Put_Hex (B : Unsigned_8);

   --  Take one received character if one is waiting. Doesn't block.
   procedure Get_Char (C : out Character; Got : out Boolean);

end Console_Text;
