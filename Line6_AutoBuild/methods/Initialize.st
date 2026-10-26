if B < 2 or B > 5 or (UseCONWIP and K < 1)
    ValidationError := "Invalid B or K"
    EventController.stop
    return
end
WIP := 0
MaxWIP := 0
NIn := 0
NOut := 0
Completed := 0
MeasuredAdmissions := 0
CohortCompleted := 0
BufferN := 0
OutsideN := 0
WIPArea := 0
BufferArea := 0
OutsideArea := 0
ResidenceSum := 0
OutsideWaitSum := 0
LastChange := 0
RunFinished := false
ValidationError := ""
A_MoveIn.entranceLocked := false
&StartStats.executeIn(Warmup)
&EndStats.executeIn(Warmup + MeasureTime)
