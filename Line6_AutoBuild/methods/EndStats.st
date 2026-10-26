Touch
TH := Completed * 3600.0 / MeasureTime
MeanWIP := WIPArea / MeasureTime
MeanBuffer := BufferArea / MeasureTime
MeanOutside := OutsideArea / MeasureTime
BlockSeconds := A_MoveOut.statBlockingTime - BlockStart
WaitSeconds := C_665.statWaitingTime - WaitStart
CheckWIP
RunFinished := ValidationError = ""
print "B=", B, " K=", K, " CONWIP=", UseCONWIP
print "Throughput/hour=", TH, " MeanWIP=", MeanWIP
print "MeanBuffer=", MeanBuffer, " OutsideQueueMean=", MeanOutside
print "Entry cohort unfinished=", MeasuredAdmissions - CohortCompleted
EventController.stop
