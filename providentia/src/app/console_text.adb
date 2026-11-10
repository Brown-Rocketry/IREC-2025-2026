--  console_text.adb

with Board;

package body Console_Text is

   Hex_Digits : constant String := "0123456789ABCDEF";

   --  Send every byte of Buf. Board.Console.Write stops early when the
   --  transmitter times out, so send the rest until it's all gone.
   procedure Send (Buf : Storage_Array) is
      First   : Storage_Offset := Buf'First;
      Written : Storage_Offset;
   begin
      while First <= Buf'Last loop
         Board.Console.Write (Buf (First .. Buf'Last), Written);
         First := First + Written;
      end loop;
   end Send;

   procedure Put (S : String) is
      Buf : Storage_Array (1 .. S'Length);
   begin
      for I in S'Range loop
         Buf (Storage_Offset (I - S'First + 1)) :=
           Storage_Element (Character'Pos (S (I)));
      end loop;
      Send (Buf);
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      New_Line;
   end Put_Line;

   procedure New_Line is
   begin
      Put (ASCII.CR & ASCII.LF);
   end New_Line;

   procedure Put_Int (N : Integer) is
      Image : constant String := Integer'Image (N);
   begin
      --  'Image puts a space in front of positive numbers
      if Image (Image'First) = ' ' then
         Put (Image (Image'First + 1 .. Image'Last));
      else
         Put (Image);
      end if;
   end Put_Int;

   procedure Put_Hex (B : Unsigned_8) is
   begin
      Put (Hex_Digits (Natural (Shift_Right (B, 4)) + 1)
           & Hex_Digits (Natural (B and 16#0F#) + 1));
   end Put_Hex;

   procedure Put_Hex (Data : Storage_Array) is
      --  built up a line at a time, since one Write per byte pair is slow
      Line : String (1 .. 2 * Data'Length);
      J    : Positive := 1;
      B    : Unsigned_8;
   begin
      for I in Data'Range loop
         B := Unsigned_8 (Data (I));
         Line (J)     := Hex_Digits (Natural (Shift_Right (B, 4)) + 1);
         Line (J + 1) := Hex_Digits (Natural (B and 16#0F#) + 1);
         J := J + 2;
      end loop;
      Put (Line);
   end Put_Hex;

   procedure Get_Char (C : out Character; Got : out Boolean) is
      Buf      : Storage_Array (1 .. 1);
      Received : Storage_Offset;
   begin
      Board.Console.Read (Buf, Received);
      Got := Received = 1;
      C   := (if Got then Character'Val (Natural (Buf (1))) else ASCII.NUL);
   end Get_Char;

end Console_Text;
