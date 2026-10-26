Touch
@.createAttr("EnteredAt", "time")
@.createAttr("InBuffer", "boolean")
@.EnteredAt := EventController.simTime
@.InBuffer := false
WIP := WIP + 1
if WIP > MaxWIP then MaxWIP := WIP end
NIn := NIn + 1
OutsideN := OutsideN - 1
if EventController.simTime >= Warmup and EventController.simTime < Warmup + MeasureTime
    MeasuredAdmissions := MeasuredAdmissions + 1
    OutsideWaitSum := OutsideWaitSum + EventController.simTime - @.OutsideAt
end
A_MoveIn.entranceLocked := UseCONWIP and WIP >= K
CheckWIP
