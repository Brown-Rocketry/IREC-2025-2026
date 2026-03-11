procedure Pico_Uart_Demo_Tests.Assertions_Enabled is
begin
   begin
      pragma Assert (False, "Should raise");
   exception
      when others =>
         return; -- properly raised
   end;
   raise Program_Error with "Assertion did not raise";
end Pico_Uart_Demo_Tests.Assertions_Enabled;
