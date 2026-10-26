var a: time := LastChange
var b: time := EventController.simTime
if a < Warmup then a := Warmup end
if b > Warmup + MeasureTime then b := Warmup + MeasureTime end
if b > a
    WIPArea := WIPArea + WIP * (b-a)
    BufferArea := BufferArea + BufferN * (b-a)
    OutsideArea := OutsideArea + OutsideN * (b-a)
end
LastChange := EventController.simTime
