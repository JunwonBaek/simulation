var destination: object
if B = 2
    destination := Slot4
elseif B = 3
    destination := Slot3
elseif B = 4
    destination := Slot2
else
    destination := Slot1
end
@.move(destination)
