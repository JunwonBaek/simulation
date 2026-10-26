Touch
WIP := WIP - 1
NOut := NOut + 1
var t: time := EventController.simTime
if t >= Warmup and t < Warmup + MeasureTime
    Completed := Completed + 1
    if @.EnteredAt >= Warmup
        ResidenceSum := ResidenceSum + t - @.EnteredAt
        CohortCompleted := CohortCompleted + 1
    end
end
A_MoveIn.entranceLocked := UseCONWIP and WIP >= K
CheckWIP
